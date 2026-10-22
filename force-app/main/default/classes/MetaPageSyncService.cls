/**
 * @class        MetaPageSyncService
 * @description  Discovers every Facebook Page the connected Meta System User has been granted
 *               access to in Business Manager (GET /me/accounts), auto-subscribes any not yet
 *               known to this org's leadgen webhook (POST /{page-id}/subscribed_apps), and
 *               creates the corresponding Meta_Page_Setting__c row — so connecting a new Page
 *               in Business Manager is the only manual step; nothing needs to be typed into
 *               Salesforce by hand. Existing Page rows (including ones an admin deactivated)
 *               are left untouched.
 */
public without sharing class MetaPageSyncService {

    public class SyncResult {
        @AuraEnabled public Integer pagesFound = 0;
        @AuraEnabled public Integer pagesAdded = 0;
        @AuraEnabled public Integer pagesSubscribeFailed = 0;
        @AuraEnabled public List<String> messages = new List<String>();
    }

    public static SyncResult syncPages() {
        SyncResult result = new SyncResult();

        List<Object> pages = listAccessiblePages();
        result.pagesFound = pages.size();

        Map<String, Meta_Page_Setting__c> existingPagesByPageId = new Map<String, Meta_Page_Setting__c>();
        for (Meta_Page_Setting__c p : Meta_Page_Setting__c.getAll().values()) {
            if (String.isNotBlank(p.Page_Id__c)) {
                existingPagesByPageId.put(p.Page_Id__c, p);
            }
        }

        List<Meta_Page_Setting__c> toUpsert = new List<Meta_Page_Setting__c>();
        for (Object pageObj : pages) {
            Map<String, Object> page = (Map<String, Object>) pageObj;
            String pageId = page.get('id') != null ? String.valueOf(page.get('id')) : null;
            String pageName = (String) page.get('name');
            String pageToken = (String) page.get('access_token');
            if (String.isBlank(pageId)) {
                continue;
            }
            if (String.isBlank(pageToken)) {
                pageToken = getPageAccessToken(pageId);
            }

            Meta_Page_Setting__c existingSetting = existingPagesByPageId.get(pageId);
            if (existingSetting != null) {
                // Automatically populate or update Page Access Token if it was previously blank or changed
                if (String.isNotBlank(pageToken) && existingSetting.Page_Access_Token__c != pageToken) {
                    existingSetting.Page_Access_Token__c = pageToken;
                    toUpsert.add(existingSetting);
                    result.messages.add('Updated Page Access Token for: ' + pageName + ' (' + pageId + ')');
                }
                continue;
            }

            Boolean subscribed = subscribePage(pageId, pageToken);
            if (subscribed) {
                // Automatically persist the permanent Page Access Token returned by Meta
                toUpsert.add(new Meta_Page_Setting__c(
                    Name = pageId,
                    Page_Id__c = pageId,
                    Page_Name__c = pageName,
                    Page_Access_Token__c = pageToken,
                    Active__c = true
                ));
                result.pagesAdded++;
                result.messages.add('Added and subscribed: ' + pageName + ' (' + pageId + ')');
            } else {
                result.pagesSubscribeFailed++;
                result.messages.add('FAILED to subscribe: ' + pageName + ' (' + pageId + ') — check Error_Log__c');
            }
        }
        if (!toUpsert.isEmpty()) {
            Database.upsert(toUpsert, AccessLevel.SYSTEM_MODE);
        }
        return result;
    }

    /**
     * @description GET /me/accounts using the System User token — returns every Page the
     *              token holder has been granted access to in Business Manager.
     */
    private static List<Object> listAccessiblePages() {
        HttpRequest req = new HttpRequest();
        // Request access_token directly so Meta returns each Page's permanent token
        req.setEndpoint('callout:Meta_Graph_API/me/accounts?fields=id,name,access_token&limit=200');
        req.setMethod('GET');

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() == 200) {
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            List<Object> data = (List<Object>) body.get('data');
            return data != null ? data : new List<Object>();
        }

        // If the configured token is a Page Access Token (rather than a User/System User token),
        // /me resolves to the Page itself, so /me/accounts returns "nonexisting field (accounts)".
        // Fall back to /me to discover this single Page directly!
        if (res.getStatusCode() == 400 && res.getBody() != null && res.getBody().contains('nonexisting field (accounts)')) {
            HttpRequest pageReq = new HttpRequest();
            pageReq.setEndpoint('callout:Meta_Graph_API/me?fields=id,name');
            pageReq.setMethod('GET');
            HttpResponse pageRes = new Http().send(pageReq);
            if (pageRes.getStatusCode() == 200) {
                Map<String, Object> pageData = (Map<String, Object>) JSON.deserializeUntyped(pageRes.getBody());
                String pId = (String) pageData.get('id');
                String pToken = getPageAccessToken(pId);
                if (String.isNotBlank(pToken)) {
                    pageData.put('access_token', pToken);
                }
                return new List<Object>{ pageData };
            }
        }

        CreateErrorLog.logFacebookError(
            'listAccessiblePages', 'MetaPageSyncService', 'Page list', new MetaPageSyncException(res.getBody()),
            null, null, null, 'Graph API /me/accounts returned ' + res.getStatusCode()
        );
        return new List<Object>();
    }

    /**
     * @description Subscribing a Page to the leadgen field requires that specific Page's own
     *              access token (not the System User token directly) per Meta's API contract.
     */
    private static Boolean subscribePage(String pageId, String pageToken) {
        if (String.isBlank(pageToken)) {
            pageToken = getPageAccessToken(pageId);
        }
        if (String.isBlank(pageToken)) {
            return false;
        }

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:Meta_Graph_API/' + pageId + '/subscribed_apps?subscribed_fields=leadgen&access_token='
            + EncodingUtil.urlEncode(pageToken, 'UTF-8'));
        req.setMethod('POST');

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            CreateErrorLog.logFacebookError(
                'subscribePage', 'MetaPageSyncService', 'Page ' + pageId, new MetaPageSyncException(res.getBody()),
                pageId, null, null, 'subscribed_apps returned ' + res.getStatusCode()
            );
            return false;
        }
        return true;
    }

    private static Boolean subscribePage(String pageId) {
        return subscribePage(pageId, null);
    }

    private static String getPageAccessToken(String pageId) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:Meta_Graph_API/' + pageId + '?fields=access_token');
        req.setMethod('GET');

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            return null;
        }
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        return (String) body.get('access_token');
    }

    public class MetaPageSyncException extends Exception {}
}