/**
 * @class        MetaLeadWebhook
 * @description  Inbound REST endpoint for Meta's Lead Ads `leadgen` webhook
 *               (https://developers.facebook.com/docs/graph-api/webhooks, page-scoped
 *               `leadgen` field). Meta calls @HttpGet once to verify the subscription
 *               (hub.mode/hub.verify_token/hub.challenge handshake), then @HttpPost on
 *               every new lead form submission.
 *
 *               Meta's webhook contract has no OAuth/session mechanism — the only
 *               authentication available is the X-Hub-Signature-256 HMAC, verified here
 *               against Meta_Integration_Setting__c.App_Secret__c. Because there is no
 *               session, this class must be exposed as an unauthenticated endpoint (e.g. a
 *               Salesforce Sites / Experience Cloud guest-user site pointed at this Apex
 *               REST class) rather than the OAuth-protected pattern used by
 *               ShowroomLookupApi/Ozonetel — see docs/07-meta-lead-ads-integration.md for
 *               the exact setup and the guest-profile least-privilege permission set to
 *               assign (Meta_Lead_Integration_Access).
 *
 *               The POST handler only verifies the signature and extracts leadgen_ids
 *               synchronously, then hands off to MetaLeadFetchQueueable for the Graph API
 *               callout + Lead upsert — keeping the webhook ack fast, as Meta expects.
 *
 *               Each webhook entry carries its own Page ID (entry.id), extracted here
 *               alongside every leadgen_id, so a single Site can serve leads from multiple
 *               connected Facebook Pages — MetaLeadFetchQueueable resolves the right Page's
 *               access token per event via Meta_Page_Config__c.
 */
@RestResource(urlMapping='/MetaLeadWebhook/*')
global with sharing class MetaLeadWebhook {

    @HttpGet
    global static void doGet() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'text/plain');

        String mode = req.params.get('hub.mode');
        String verifyToken = req.params.get('hub.verify_token');
        String challenge = req.params.get('hub.challenge');

        Meta_Integration_Config__c setting = getSetting();
        Boolean tokenOk = setting != null
            && String.isNotBlank(setting.Verify_Token__c)
            && setting.Verify_Token__c == verifyToken;

        System.debug(LoggingLevel.INFO, '[MetaLeadWebhook.doGet] mode=' + mode
            + ' tokenOk=' + tokenOk + ' settingConfigured=' + (setting != null)
            + ' challengePresent=' + String.isNotBlank(challenge));

        if (mode == 'subscribe' && tokenOk && String.isNotBlank(challenge)) {
            res.statusCode = 200;
            res.responseBody = Blob.valueOf(challenge);
            System.debug(LoggingLevel.INFO, '[MetaLeadWebhook.doGet] handshake OK, echoing challenge');
        } else {
            res.statusCode = 403;
            res.responseBody = Blob.valueOf('Verification failed');
            System.debug(LoggingLevel.WARN, '[MetaLeadWebhook.doGet] handshake FAILED — check hub.verify_token matches Meta_Integration_Setting__c (Setting_Key__c=Default).Verify_Token__c');
        }
    }

    @HttpPost
    global static void doPost() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        String rawBody = req.requestBody != null ? req.requestBody.toString() : '';
        String signatureHeader = getHeader(req.headers, 'X-Hub-Signature-256');
        System.debug(LoggingLevel.INFO, '[MetaLeadWebhook.doPost] received ' + rawBody.length() + ' bytes, signatureHeaderPresent='
            + String.isNotBlank(signatureHeader));

        if (!isValidSignature(rawBody, signatureHeader)) {
            System.debug(LoggingLevel.WARN, '[MetaLeadWebhook.doPost] signature INVALID — check App_Secret__c matches the Meta App\'s secret. Body: ' + truncate(rawBody));
            CreateErrorLog.logFacebookError(
                'doPost', 'MetaLeadWebhook', 'Lead',
                new MetaWebhookException('Signature verification failed or missing'),
                null, null, null,
                'Rejected webhook call with invalid/missing X-Hub-Signature-256. Raw payload: ' + truncate(rawBody)
            );
            res.statusCode = 403;
            res.responseBody = Blob.valueOf('Invalid signature');
            return;
        }

        List<MetaLeadgenEvent> leadgenEvents;
        try {
            leadgenEvents = extractLeadgenIds(rawBody);
        } catch (Exception e) {
            CreateErrorLog.logFacebookError(
                'doPost', 'MetaLeadWebhook', 'Lead', e,
                null, null, null,
                'Malformed webhook payload: ' + truncate(rawBody)
            );
            // Ack 200 anyway so Meta does not keep retrying a payload we will never be
            // able to parse.
            res.statusCode = 200;
            res.responseBody = Blob.valueOf('EVENT_RECEIVED');
            return;
        }

        List<String> eventSummaries = new List<String>();
        for (MetaLeadgenEvent evt : leadgenEvents) {
            eventSummaries.add('(leadgen_id=' + evt.leadgenId + ', page_id=' + evt.pageId + ')');
        }
        System.debug(LoggingLevel.INFO, '[MetaLeadWebhook.doPost] signature OK, extracted ' + leadgenEvents.size()
            + ' leadgen event(s): ' + String.join(eventSummaries, ', '));

        if (!leadgenEvents.isEmpty()) {
            MetaLeadFetchQueueable.enqueue(leadgenEvents);
            System.debug(LoggingLevel.INFO, '[MetaLeadWebhook.doPost] enqueued MetaLeadFetchQueueable — check Setup > Apex Jobs, then debug logs for [MetaLeadFetchQueueable] lines');
        }

        res.statusCode = 200;
        res.responseBody = Blob.valueOf('EVENT_RECEIVED');
    }

    @TestVisible
    private static Boolean isValidSignature(String rawBody, String signatureHeader) {
        if (String.isBlank(signatureHeader) || !signatureHeader.startsWith('sha256=')) {
            return false;
        }
        Meta_Integration_Config__c setting = getSetting();
        if (setting == null || String.isBlank(setting.App_Secret__c)) {
            return false;
        }

        String providedHex = signatureHeader.substring(7).toLowerCase();
        Blob mac = Crypto.generateMac('hmacSHA256', Blob.valueOf(rawBody), Blob.valueOf(setting.App_Secret__c));
        String computedHex = EncodingUtil.convertToHex(mac).toLowerCase();
        return computedHex == providedHex;
    }

    @TestVisible
    private static List<MetaLeadgenEvent> extractLeadgenIds(String rawBody) {
        List<MetaLeadgenEvent> events = new List<MetaLeadgenEvent>();
        Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(rawBody);
        List<Object> entries = (List<Object>) root.get('entry');
        if (entries == null) {
            return events;
        }

        for (Object entryObj : entries) {
            Map<String, Object> entry = (Map<String, Object>) entryObj;
            // The Page (or other subscribed object) this entry is for. Carried alongside each
            // leadgen_id so MetaLeadFetchQueueable can resolve the right Page's access token
            // before calling the Graph API — needed once more than one Page is connected.
            String pageId = entry.get('id') != null ? String.valueOf(entry.get('id')) : null;
            List<Object> changes = (List<Object>) entry.get('changes');
            if (changes == null) {
                continue;
            }
            for (Object changeObj : changes) {
                Map<String, Object> change = (Map<String, Object>) changeObj;
                if (change.get('field') != 'leadgen') {
                    continue;
                }
                Map<String, Object> value = (Map<String, Object>) change.get('value');
                if (value != null && value.get('leadgen_id') != null) {
                    events.add(new MetaLeadgenEvent(String.valueOf(value.get('leadgen_id')), pageId));
                }
            }
        }
        return events;
    }

    @TestVisible
    private static Meta_Integration_Config__c cachedSetting;

    private static Meta_Integration_Config__c getSetting() {
        if (cachedSetting == null) {
            // Meta_Integration_Config__c is a Hierarchy Custom Setting. getOrgDefaults() (the
            // generated cached accessor) is always readable by Apex — including the Guest User
            // running this webhook — regardless of sharing/FLS; a plain SOQL SELECT against a
            // Custom Setting does NOT get this same bypass for Guest context.
            Meta_Integration_Config__c orgDefaults = Meta_Integration_Config__c.getOrgDefaults();
            cachedSetting = (orgDefaults.Id != null) ? orgDefaults : null;
        }
        return cachedSetting;
    }

    private static String getHeader(Map<String, String> headers, String targetKey) {
        if (headers == null || String.isBlank(targetKey)) {
            return null;
        }
        if (headers.containsKey(targetKey)) {
            return headers.get(targetKey);
        }
        for (String key : headers.keySet()) {
            if (key != null && key.equalsIgnoreCase(targetKey)) {
                return headers.get(key);
            }
        }
        return null;
    }

    private static String truncate(String s) {
        Integer maxLen = 10000;
        if (s == null) {
            return '';
        }
        return s.length() > maxLen
            ? s.substring(0, maxLen) + '... [truncated, total ' + s.length() + ' chars]'
            : s;
    }

    public class MetaWebhookException extends Exception {}
}