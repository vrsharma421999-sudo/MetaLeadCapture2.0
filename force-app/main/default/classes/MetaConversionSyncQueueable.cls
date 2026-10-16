/**
 * @class        MetaConversionSyncQueueable
 * @description  Sends Pending/retryable Meta_Conversion_Event__c rows to Meta's Conversions
 *               API for Leads (POST /{Dataset_ID}/events), per
 *               developers.facebook.com/documentation/ads-commerce/conversions-api/
 *               conversion-leads-integration/crm-integration — event_name, event_time,
 *               action_source="system_generated", event_source="crm", lead_event_source, and
 *               user_data.lead_id (the leadgen_id — Meta's highest-priority match key).
 *
 *               Batches are capped well under Meta's 1,000-event/request limit: Meta's own
 *               guidance is that a bad event fails the WHOLE batch, so smaller batches with
 *               retry logic are preferable to one huge one. A batch that fails is marked
 *               Failed in full and picked up again later by MetaConversionSyncScheduler, up
 *               to Meta_Integration_Setting__c (Setting_Key__c='Default').Max_Conversion_Sync_Attempts__c.
 *
 *               Invoked by LeadConversionSyncHandler's Pending inserts (via
 *               MetaConversionSyncScheduler on a timer — not directly from the Lead trigger,
 *               so this class's Named-Credential/token access doesn't need to be granted to
 *               every profile that edits Leads) and can also be enqueued directly for an
 *               immediate send.
 */
public without sharing class MetaConversionSyncQueueable implements Queueable, Database.AllowsCallouts {
    private static final Integer BATCH_SIZE = 25;
    private static final String DEFAULT_GRAPH_API_VERSION = 'v21.0';

    public void execute(QueueableContext qc) {
        Meta_Integration_Config__c setting = getSetting();
        if (setting == null || String.isBlank(setting.Dataset_ID__c)) {
            System.debug(LoggingLevel.WARN, '[MetaConversionSyncQueueable.execute] Dataset_ID__c not configured on Meta_Integration_Setting__c (Setting_Key__c=Default) — skipping this run.');
            return;
        }
        Integer maxAttempts = setting.Max_Conversion_Sync_Attempts__c != null
            ? Integer.valueOf(setting.Max_Conversion_Sync_Attempts__c) : 5;

        List<Meta_Conversion_Event__c> toSend = [
            SELECT Id, Leadgen_Id__c, Event_Name__c, Event_Time__c, Attempts__c
            FROM Meta_Conversion_Event__c
            WHERE Status__c IN ('Pending', 'Failed') AND Attempts__c < :maxAttempts
            ORDER BY CreatedDate ASC
            LIMIT :BATCH_SIZE
        ];
        System.debug(LoggingLevel.INFO, '[MetaConversionSyncQueueable.execute] found ' + toSend.size() + ' event(s) to send (batch size cap ' + BATCH_SIZE + ')');
        if (toSend.isEmpty()) {
            return;
        }

        sendBatch(toSend, setting);

        // More may be waiting behind this batch — chain another job rather than making the
        // caller enqueue repeatedly.
        List<Meta_Conversion_Event__c> remaining = [
            SELECT Id FROM Meta_Conversion_Event__c
            WHERE Status__c IN ('Pending', 'Failed') AND Attempts__c < :maxAttempts
            LIMIT 1
        ];
        if (!remaining.isEmpty() && !Test.isRunningTest()) {
            System.enqueueJob(new MetaConversionSyncQueueable());
        }
    }

    private void sendBatch(List<Meta_Conversion_Event__c> events, Meta_Integration_Config__c setting) {
        String leadEventSource = String.isNotBlank(setting.Lead_Event_Source__c) ? setting.Lead_Event_Source__c : 'Salesforce';
        String graphApiVersion = String.isNotBlank(setting.Graph_API_Version__c) ? setting.Graph_API_Version__c : DEFAULT_GRAPH_API_VERSION;

        List<Object> data = new List<Object>();
        for (Meta_Conversion_Event__c evt : events) {
            data.add(new Map<String, Object>{
                'event_name' => evt.Event_Name__c,
                'event_time' => evt.Event_Time__c.getTime() / 1000,
                'action_source' => 'system_generated',
                'event_source' => 'crm',
                'lead_event_source' => leadEventSource,
                'user_data' => new Map<String, Object>{
                    'lead_id' => evt.Leadgen_Id__c
                }
            });
        }
        String body = JSON.serialize(new Map<String, Object>{ 'data' => data });

        // Auth via Named Credential (Meta_Graph_API) + External Credential (Meta_Graph_API_Cred) —
        // same System User token used for inbound lead retrieval, granted ads_management on this
        // dataset's ad account. Token is injected by the platform, never held in Apex/data.
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:Meta_Graph_API/' + graphApiVersion + '/' + setting.Dataset_ID__c + '/events');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setBody(body);

        String responseBody;
        Boolean success;
        try {
            HttpResponse res = new Http().send(req);
            responseBody = res.getBody();
            success = res.getStatusCode() >= 200 && res.getStatusCode() < 300;
        } catch (Exception e) {
            responseBody = 'Callout exception: ' + e.getMessage();
            success = false;
        }
        System.debug(LoggingLevel.INFO, '[MetaConversionSyncQueueable.sendBatch] sent ' + events.size() + ' event(s) to Dataset '
            + setting.Dataset_ID__c + ' -> success=' + success + ' response=' + truncate(responseBody, 500));

        List<Meta_Conversion_Event__c> toUpdate = new List<Meta_Conversion_Event__c>();
        for (Meta_Conversion_Event__c evt : events) {
            toUpdate.add(new Meta_Conversion_Event__c(
                Id = evt.Id,
                Status__c = success ? 'Sent' : 'Failed',
                Response__c = truncate(responseBody, 32000),
                Attempts__c = (evt.Attempts__c == null ? 0 : evt.Attempts__c) + 1,
                Last_Attempt__c = System.now()
            ));
        }
        Database.update(toUpdate, AccessLevel.SYSTEM_MODE);

        if (!success) {
            CreateErrorLog.logFacebookError(
                'sendBatch', 'MetaConversionSyncQueueable', 'Meta_Conversion_Event__c batch of ' + events.size(),
                new MetaConversionsApiException(responseBody), null, null, null,
                'Outbound Conversions API batch send failed.'
            );
        }
    }

    @TestVisible private static Meta_Integration_Config__c cachedSetting;

    private static Meta_Integration_Config__c getSetting() {
        if (cachedSetting == null) {
            Meta_Integration_Config__c orgDefaults = Meta_Integration_Config__c.getOrgDefaults();
            cachedSetting = (orgDefaults.Id != null) ? orgDefaults : null;
        }
        return cachedSetting;
    }

    private static String truncate(String s, Integer maxLen) {
        if (s == null) {
            return '';
        }
        return s.length() > maxLen
            ? s.substring(0, maxLen) + '... [truncated, total ' + s.length() + ' chars]'
            : s;
    }

    public class MetaConversionsApiException extends Exception {}
}