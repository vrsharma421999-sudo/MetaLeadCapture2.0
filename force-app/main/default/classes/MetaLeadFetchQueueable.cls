/**
 * @class        MetaLeadFetchQueueable
 * @description  Async follow-up to MetaLeadWebhook.doPost(). For each (leadgen_id, page_id)
 *               from the webhook, calls the Graph API (GET /{leadgen_id}) via the literal
 *               https://graph.facebook.com endpoint (Meta_Graph_API Remote Site Setting —
 *               matches this org's existing pattern of literal-endpoint callouts, e.g.
 *               OzenTelClicktoCallClass, rather than Named Credentials) to retrieve
 *               field_data, then delegates the actual Lead upsert to MetaLeadMapper.
 *
 *               Multi-Page support: the Page Access Token used for each callout is looked up
 *               per event from Meta_Page_Config__c by Page_Id__c, so a customer with many
 *               connected Facebook Pages manages them as data (add a row on the Meta Lead
 *               Capture Setup page) instead of an Apex/permission-set change. Meta_Page_Config__c
 *               is a custom object rather than Custom Metadata specifically so this list is
 *               per-org data — deploying to a different org never adds/overwrites its Pages.
 *
 *               No-data-loss: any failure — unknown/inactive Page, a non-200 from the Graph
 *               API, or the Lead insert/update itself being rejected (validation rule,
 *               duplicate rule, required field) — is captured as a Meta_Lead_Sync_Failure__c
 *               record (with the full fetched payload, when we have one) instead of only a
 *               text description in Error_Log__c, so a failed lead can always be inspected
 *               and resent later via MetaLeadSyncFailureResend rather than being lost.
 */
public without sharing class MetaLeadFetchQueueable implements Queueable, Database.AllowsCallouts {
    private static final Integer MAX_LEADS_PER_JOB = 50;
    private static final String DEFAULT_GRAPH_API_VERSION = 'v21.0';

    @TestVisible private List<MetaLeadgenEvent> leadgenEvents;

    public MetaLeadFetchQueueable(List<MetaLeadgenEvent> leadgenEvents) {
        this.leadgenEvents = leadgenEvents;
    }

    public static void enqueue(List<MetaLeadgenEvent> leadgenEvents) {
        if (leadgenEvents == null || leadgenEvents.isEmpty()) {
            return;
        }
        List<MetaLeadgenEvent> currentBatch = new List<MetaLeadgenEvent>();
        for (MetaLeadgenEvent evt : leadgenEvents) {
            currentBatch.add(evt);
            if (currentBatch.size() == MAX_LEADS_PER_JOB) {
                System.enqueueJob(new MetaLeadFetchQueueable(currentBatch));
                currentBatch = new List<MetaLeadgenEvent>();
            }
        }
        if (!currentBatch.isEmpty()) {
            System.enqueueJob(new MetaLeadFetchQueueable(currentBatch));
        }
    }

    public void execute(QueueableContext qc) {
        System.debug(LoggingLevel.INFO, '[MetaLeadFetchQueueable.execute] processing batch of ' + leadgenEvents.size() + ' event(s)');
        for (MetaLeadgenEvent evt : leadgenEvents) {
            try {
                processOneLead(evt);
            } catch (Exception e) {
                // Last-resort catch: processOneLead already dead-letters the failures it
                // expects (bad config, callout error, DML error). This only fires for
                // something genuinely unexpected, so still preserve it rather than losing
                // the lead silently.
                deadLetter(evt, null, 'Unexpected error: ' + e.getMessage() + ' (' + e.getTypeName() + ')');
                CreateErrorLog.logFacebookError(
                    'execute', 'MetaLeadFetchQueueable', 'Lead leadgen_id=' + evt.leadgenId, e,
                    evt.pageId, null, null,
                    'Unexpected failure processing leadgen_id ' + evt.leadgenId
                );
            }
        }
    }

    @TestVisible
    private void processOneLead(MetaLeadgenEvent evt) {
        System.debug(LoggingLevel.INFO, '[MetaLeadFetchQueueable.processOneLead] START leadgen_id=' + evt.leadgenId + ' page_id=' + evt.pageId);
        Map<String, Object> payload;
        try {
            payload = fetchPayload(evt.leadgenId, evt.pageId);
            System.debug(LoggingLevel.INFO, '[MetaLeadFetchQueueable.processOneLead] Graph API fetch OK for leadgen_id=' + evt.leadgenId
                + ' — field_data present=' + (payload.get('field_data') != null));
        } catch (MetaGraphApiException e) {
            System.debug(LoggingLevel.WARN, '[MetaLeadFetchQueueable.processOneLead] Graph API fetch FAILED for leadgen_id=' + evt.leadgenId
                + ': ' + e.getMessage() + ' — dead-lettering, check Meta_Lead_Sync_Failure__c');
            deadLetter(evt, null, e.getMessage());
            CreateErrorLog.logFacebookError(
                'processOneLead', 'MetaLeadFetchQueueable', 'Lead leadgen_id=' + evt.leadgenId,
                e, evt.pageId, null, null, e.getMessage()
            );
            return;
        }

        try {
            Lead saved = MetaLeadMapper.upsertLeadFromPayload(evt.leadgenId, payload);
            System.debug(LoggingLevel.INFO, '[MetaLeadFetchQueueable.processOneLead] SUCCESS — Lead ' + saved.Id + ' saved for leadgen_id=' + evt.leadgenId);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[MetaLeadFetchQueueable.processOneLead] Lead save FAILED for leadgen_id=' + evt.leadgenId
                + ': ' + e.getMessage() + ' — dead-lettering with the fetched payload, check Meta_Lead_Sync_Failure__c');
            deadLetter(evt, JSON.serialize(payload), e.getMessage() + ' (' + e.getTypeName() + ')');
            CreateErrorLog.logFacebookError(
                'processOneLead', 'MetaLeadFetchQueueable', 'Lead leadgen_id=' + evt.leadgenId, e,
                evt.pageId, null, null,
                'Fetched lead payload but could not save it as a Lead.'
            );
        }
    }

    /**
     * @description Resolves the Page's access token and calls the Graph API for one
     *              leadgen_id. Public/static so MetaLeadSyncFailureResend can re-fetch a
     *              payload for a dead-lettered event that never got one (e.g. the Page
     *              config didn't exist yet at the time of the original webhook call), using
     *              the exact same callout logic rather than a second copy of it.
     * @throws MetaGraphApiException if there's no active Page config or the callout doesn't
     *              return 200.
     */
    public static Map<String, Object> fetchPayload(String leadgenId, String pageId) {
        Meta_Page_Setting__c pageConfig = getPageConfig(pageId);
        if (pageConfig == null) {
            throw new MetaGraphApiException('No active Meta_Page_Setting__c record found for Page Id '
                + pageId + '. Add/activate a Page config record on the Meta Lead Capture Setup page with this Page_Id__c.');
        }

        // Auth via Named Credential (Meta_Graph_API) + External Credential (Meta_Graph_API_Cred) —
        // the Meta System User token is injected by the platform, never held in Apex/data. One
        // token covers every Page the System User has been granted access to in Business Manager,
        // so no per-Page token is needed here (see docs/meta-lead-ads-integration.md).
        HttpRequest req = new HttpRequest();
        // NOTE: page_id is deliberately NOT requested here — it is not a valid queryable field
        // on the Graph API's /{leadgen_id} GET response (it only appears in the webhook POST
        // payload, which is where pageId already came from). Requesting it causes Meta to
        // reject the whole call with (#100) "Tried accessing nonexisting field (page_id)".
        req.setEndpoint('callout:Meta_Graph_API/' + getGraphApiVersion() + '/' + leadgenId
            + '?fields=field_data,ad_id,adset_id,campaign_id,form_id,created_time');
        req.setMethod('GET');

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            throw new MetaGraphApiException('Graph API returned ' + res.getStatusCode() + ' for leadgen_id '
                + leadgenId + ': ' + truncate(res.getBody(), 30000));
        }
        Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        // Backfill page_id from the webhook event rather than the Graph API response, since the
        // API doesn't return it — MetaLeadMapper still expects this key to be present.
        payload.put('page_id', pageId);
        return payload;
    }

    /**
     * @description Persists a Meta_Lead_Sync_Failure__c so the lead can be inspected/resent
     *              later, and fires the failure notification. Inserted in system mode (like
     *              CreateErrorLog) so this works regardless of the running user's object
     *              access — this runs from the guest-user-initiated webhook path.
     */
    private void deadLetter(MetaLeadgenEvent evt, String rawPayloadJson, String reason) {
        try {
            Meta_Lead_Sync_Failure__c failure = new Meta_Lead_Sync_Failure__c(
                Leadgen_Id__c = evt.leadgenId,
                Page_Id__c = evt.pageId,
                Raw_Payload__c = rawPayloadJson != null ? truncate(rawPayloadJson, 131000) : null,
                Failure_Reason__c = truncate(reason, 32000),
                Status__c = 'New',
                Attempts__c = 1,
                Last_Attempt__c = System.now()
            );
            Database.insert(failure, AccessLevel.SYSTEM_MODE);
            System.debug(LoggingLevel.INFO, '[MetaLeadFetchQueueable.deadLetter] Meta_Lead_Sync_Failure__c ' + failure.Id
                + ' created for leadgen_id=' + evt.leadgenId + ' — notification should fire via MetaLeadSyncFailureTrigger');
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, '[MetaLeadFetchQueueable.deadLetter] FAILED to dead-letter leadgen_id ' + evt.leadgenId + ': ' + ex.getMessage());
        }
    }

    @TestVisible private static Map<String, Meta_Page_Setting__c> pageConfigCache;

    private static Meta_Page_Setting__c getPageConfig(String pageId) {
        if (pageConfigCache == null) {
            pageConfigCache = new Map<String, Meta_Page_Setting__c>();
            // getAll() (the generated cached accessor) is always readable by Apex — including
            // the Guest User running the webhook that enqueued this queueable — regardless of
            // sharing/FLS; a plain SOQL SELECT against a Custom Setting does NOT get this same
            // bypass for Guest context.
            for (Meta_Page_Setting__c cfg : Meta_Page_Setting__c.getAll().values()) {
                if (cfg.Active__c && String.isNotBlank(cfg.Page_Id__c)) {
                    pageConfigCache.put(cfg.Page_Id__c, cfg);
                }
            }
        }
        return pageId != null ? pageConfigCache.get(pageId) : null;
    }

    @TestVisible private static Meta_Integration_Config__c cachedSetting;

    private static Meta_Integration_Config__c getSetting() {
        if (cachedSetting == null) {
            Meta_Integration_Config__c orgDefaults = Meta_Integration_Config__c.getOrgDefaults();
            cachedSetting = (orgDefaults.Id != null) ? orgDefaults : null;
        }
        return cachedSetting;
    }

    private static String getGraphApiVersion() {
        Meta_Integration_Config__c setting = getSetting();
        return (setting != null && String.isNotBlank(setting.Graph_API_Version__c))
            ? setting.Graph_API_Version__c
            : DEFAULT_GRAPH_API_VERSION;
    }

    private static String truncate(String s, Integer maxLen) {
        if (s == null) {
            return '';
        }
        return s.length() > maxLen
            ? s.substring(0, maxLen) + '... [truncated, total ' + s.length() + ' chars]'
            : s;
    }

    public class MetaGraphApiException extends Exception {}
}