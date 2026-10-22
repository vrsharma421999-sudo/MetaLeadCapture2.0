/**
 * @class        MetaOAuthConnectService
 * @description  Powers the "Connect to Meta" embedded Facebook Login button on the Setup
 *               page's Integration Settings tab. Deliberately fully self-contained: it stores
 *               its own token (Meta_Integration_Config__c.Meta_User_Access_Token__c) and makes
 *               its own direct Graph API calls, entirely separate from the Named
 *               Credential/System User token that MetaLeadFetchQueueable,
 *               MetaConversionSyncQueueable, MetaPageSyncService and MetaFormSyncService use
 *               for the actual lead-capture pipeline. Connecting (or reconnecting) here never
 *               touches, reads, or risks that already-working path — its only side effect on
 *               the rest of the app is writing ordinary Meta_Page_Setting__c /
 *               Meta_Field_Map__c rows, exactly like a manual "Sync Pages from Meta" /
 *               "Discover Forms & Questions" click would.
 */
public without sharing class MetaOAuthConnectService {

    private static final String GRAPH_HOST = 'https://graph.facebook.com';
    private static final String DEFAULT_VERSION = 'v21.0';

    public class ConnectResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;
        @AuraEnabled public Integer pagesFound = 0;
        @AuraEnabled public Integer pagesAdded = 0;
        @AuraEnabled public Integer formsFound = 0;
        @AuraEnabled public Integer newMappingsAdded = 0;
    }

    public static ConnectResult connect(String code, String redirectUri) {
        ConnectResult result = new ConnectResult();
        Meta_Integration_Config__c setting = Meta_Integration_Config__c.getOrgDefaults();
        if (String.isBlank(setting.Meta_App_Id__c) || String.isBlank(setting.App_Secret__c)) {
            result.success = false;
            result.message = 'Set Meta App Id and App Secret on this tab first, then try Connect to Meta again.';
            return result;
        }

        Map<String, Object> shortLived = callOAuthEndpoint(new Map<String, String>{
            'client_id' => setting.Meta_App_Id__c,
            'client_secret' => setting.App_Secret__c,
            'redirect_uri' => redirectUri,
            'code' => code
        });
        if (shortLived == null || shortLived.get('access_token') == null) {
            result.success = false;
            result.message = 'Facebook rejected the authorization code — try connecting again.';
            return result;
        }

        Map<String, Object> longLived = callOAuthEndpoint(new Map<String, String>{
            'grant_type' => 'fb_exchange_token',
            'client_id' => setting.Meta_App_Id__c,
            'client_secret' => setting.App_Secret__c,
            'fb_exchange_token' => (String) shortLived.get('access_token')
        });
        if (longLived == null || longLived.get('access_token') == null) {
            result.success = false;
            result.message = 'Connected, but could not exchange for a long-lived token — try again.';
            return result;
        }

        String longLivedToken = (String) longLived.get('access_token');
        Integer expiresIn = longLived.get('expires_in') != null ? Integer.valueOf(longLived.get('expires_in')) : 5184000;

        result.success = true;
        result.message = 'Connected to Meta.';
        // Discovery runs BEFORE any DML: Salesforce forbids a callout after uncommitted DML in
        // the same transaction, and discovery makes several more callouts (list Pages, per-Page
        // subscribe, list Forms, list questions) — saving the token first would make every one
        // of those throw "uncommitted work pending", silently caught below and looking like an
        // empty result. runDiscovery itself follows the same rule internally: all of its
        // callouts happen before any of its own DML.
        runDiscovery(longLivedToken, setting.Graph_API_Version__c, result);

        setting.Meta_User_Access_Token__c = longLivedToken;
        setting.Meta_Token_Expires_At__c = Datetime.now().addSeconds(expiresIn);
        upsert setting;

        return result;
    }

    /**
     * @description Best-effort: a discovery hiccup (a Page missing leadgen permission, a
     *              transient Graph API error, etc.) appends a note to the result rather than
     *              making the connection itself look failed — Sync Pages from Meta / Discover
     *              Forms & Questions on their own tabs can always retry it. All callouts this
     *              method makes happen before its two DML statements (never interleaved), per
     *              the platform rule that a callout can't follow uncommitted DML in the same
     *              transaction.
     */
    private static void runDiscovery(String token, String graphApiVersion, ConnectResult result) {
        String version = String.isNotBlank(graphApiVersion) ? graphApiVersion : DEFAULT_VERSION;
        try {
            Map<String, Meta_Page_Setting__c> existingPagesByPageId = new Map<String, Meta_Page_Setting__c>();
            for (Meta_Page_Setting__c p : Meta_Page_Setting__c.getAll().values()) {
                if (String.isNotBlank(p.Page_Id__c)) {
                    existingPagesByPageId.put(p.Page_Id__c, p);
                }
            }

            List<Object> pages = listPages(token, version);
            result.pagesFound = pages.size();

            // Callout phase: collect new/updated Pages (subscribing each) and every active Page's forms
            // + questions, all in memory — no DML until every callout below is done.
            List<Meta_Page_Setting__c> pagesToUpsert = new List<Meta_Page_Setting__c>();
            List<String> pageIdsToScanForForms = new List<String>();
            for (Meta_Page_Setting__c p : existingPagesByPageId.values()) {
                if (p.Active__c && String.isNotBlank(p.Page_Id__c)) {
                    pageIdsToScanForForms.add(p.Page_Id__c);
                }
            }
            for (Object pageObj : pages) {
                Map<String, Object> page = (Map<String, Object>) pageObj;
                String pageId = page.get('id') != null ? String.valueOf(page.get('id')) : null;
                String pageName = (String) page.get('name');
                String pageToken = (String) page.get('access_token');
                if (String.isBlank(pageId)) {
                    continue;
                }
                Meta_Page_Setting__c existingSetting = existingPagesByPageId.get(pageId);
                if (existingSetting != null) {
                    // Automatically backfill or refresh Page Access Token on existing page configs
                    if (String.isNotBlank(pageToken) && existingSetting.Page_Access_Token__c != pageToken) {
                        existingSetting.Page_Access_Token__c = pageToken;
                        pagesToUpsert.add(existingSetting);
                    }
                    continue;
                }
                if (String.isNotBlank(pageToken)) {
                    subscribePage(pageId, pageToken, version);
                }
                // Automatically persist the permanent Page Access Token returned by Meta
                pagesToUpsert.add(new Meta_Page_Setting__c(
                    Name = pageId,
                    Page_Id__c = pageId,
                    Page_Name__c = pageName,
                    Page_Access_Token__c = pageToken,
                    Active__c = true
                ));
                pageIdsToScanForForms.add(pageId);
                result.pagesAdded++;
            }

            Set<String> existingMappingKeys = new Set<String>();
            for (Meta_Field_Map__c m : Meta_Field_Map__c.getAll().values()) {
                if (String.isNotBlank(m.Form_Id__c) && String.isNotBlank(m.Meta_Field_Key__c)) {
                    existingMappingKeys.add(m.Form_Id__c + '_' + m.Meta_Field_Key__c.toLowerCase());
                }
            }

            List<Meta_Field_Map__c> mappingsToInsert = new List<Meta_Field_Map__c>();
            // Scan forms across every active Page (existing ones plus any just discovered
            // above), so reconnecting after adding a Page in Business Manager still picks up
            // its forms in the same run.
            for (String pageId : pageIdsToScanForForms) {
                for (Object formObj : listForms(pageId, token, version)) {
                    Map<String, Object> form = (Map<String, Object>) formObj;
                    String formId = form.get('id') != null ? String.valueOf(form.get('id')) : null;
                    String formName = (String) form.get('name');
                    if (String.isBlank(formId)) {
                        continue;
                    }
                    result.formsFound++;
                    for (Object qObj : listQuestions(formId, token, version)) {
                        Map<String, Object> q = (Map<String, Object>) qObj;
                        String key = (String) q.get('key');
                        String label = (String) q.get('label');
                        if (String.isBlank(key)) {
                            continue;
                        }
                        String uKey = formId + '_' + key.toLowerCase();
                        if (existingMappingKeys.contains(uKey)) {
                            continue;
                        }
                        existingMappingKeys.add(uKey);
                        mappingsToInsert.add(new Meta_Field_Map__c(
                            Name = uKey.length() > 80 ? uKey.substring(0, 80) : uKey,
                            Form_Id__c = formId, Form_Name__c = formName,
                            Meta_Field_Key__c = key, Meta_Field_Label__c = label,
                            Salesforce_Field_API_Name__c = null, Active__c = false
                        ));
                        result.newMappingsAdded++;
                    }
                }
            }

            // DML phase: every callout above is done — safe to write now.
            if (!pagesToUpsert.isEmpty()) {
                Database.upsert(pagesToUpsert, AccessLevel.SYSTEM_MODE);
            }
            if (!mappingsToInsert.isEmpty()) {
                Database.insert(mappingsToInsert, AccessLevel.SYSTEM_MODE);
            }
        } catch (Exception e) {
            result.message = 'Connected, but Page/Form discovery hit an error: ' + e.getMessage()
                + ' — use Sync Pages from Meta / Discover Forms & Questions to retry.';
            CreateErrorLog.logFacebookError(
                'runDiscovery', 'MetaOAuthConnectService', 'Post-connect discovery', e,
                null, null, null, 'Auto-discovery after Connect to Meta failed.'
            );
        }
    }

    private static List<Object> listPages(String token, String version) {
        HttpResponse res = get(GRAPH_HOST + '/' + version + '/me/accounts?fields=id,name,access_token&limit=200', token);
        if (res.getStatusCode() != 200) {
            CreateErrorLog.logFacebookError(
                'listPages', 'MetaOAuthConnectService', 'Page list', new MetaOAuthException(res.getBody()),
                null, null, null, '/me/accounts returned ' + res.getStatusCode()
            );
            return new List<Object>();
        }
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> data = (List<Object>) body.get('data');
        return data != null ? data : new List<Object>();
    }

    private static void subscribePage(String pageId, String pageToken, String version) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(GRAPH_HOST + '/' + version + '/' + pageId + '/subscribed_apps?subscribed_fields=leadgen&access_token='
            + EncodingUtil.urlEncode(pageToken, 'UTF-8'));
        req.setMethod('POST');
        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            CreateErrorLog.logFacebookError(
                'subscribePage', 'MetaOAuthConnectService', 'Page ' + pageId, new MetaOAuthException(res.getBody()),
                pageId, null, null, 'subscribed_apps returned ' + res.getStatusCode()
            );
        }
    }

    private static List<Object> listForms(String pageId, String token, String version) {
        HttpResponse res = get(GRAPH_HOST + '/' + version + '/' + pageId + '/leadgen_forms?fields=id,name&limit=200', token);
        if (res.getStatusCode() != 200) {
            return new List<Object>();
        }
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> data = (List<Object>) body.get('data');
        return data != null ? data : new List<Object>();
    }

    private static List<Object> listQuestions(String formId, String token, String version) {
        HttpResponse res = get(GRAPH_HOST + '/' + version + '/' + formId + '?fields=questions', token);
        if (res.getStatusCode() != 200) {
            return new List<Object>();
        }
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> questions = (List<Object>) body.get('questions');
        return questions != null ? questions : new List<Object>();
    }

    private static HttpResponse get(String url, String token) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(url + (url.contains('?') ? '&' : '?') + 'access_token=' + EncodingUtil.urlEncode(token, 'UTF-8'));
        req.setMethod('GET');
        return new Http().send(req);
    }

    private static Map<String, Object> callOAuthEndpoint(Map<String, String> params) {
        List<String> parts = new List<String>();
        for (String key : params.keySet()) {
            parts.add(key + '=' + EncodingUtil.urlEncode(params.get(key), 'UTF-8'));
        }
        HttpRequest req = new HttpRequest();
        req.setEndpoint(GRAPH_HOST + '/' + DEFAULT_VERSION + '/oauth/access_token?' + String.join(parts, '&'));
        req.setMethod('GET');
        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            CreateErrorLog.logFacebookError(
                'callOAuthEndpoint', 'MetaOAuthConnectService', 'OAuth token exchange', new MetaOAuthException(res.getBody()),
                null, null, null, 'oauth/access_token returned ' + res.getStatusCode()
            );
            return null;
        }
        return (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
    }

    public class MetaOAuthException extends Exception {}
}