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

        Set<String> existingPageIds = new Set<String>();
        for (Meta_Page_Setting__c p : Meta_Page_Setting__c.getAll().values()) {
            if (String.isNotBlank(p.Page_Id__c)) {
                existingPageIds.add(p.Page_Id__c);
            }
        }

        List<Meta_Page_Setting__c> toInsert = new List<Meta_Page_Setting__c>();
        for (Object pageObj : pages) {
            Map<String, Object> page = (Map<String, Object>) pageObj;
            String pageId = page.get('id') != null ? String.valueOf(page.get('id')) : null;
            String pageName = (String) page.get('name');
            if (String.isBlank(pageId) || existingPageIds.contains(pageId)) {
                continue;
            }

            Boolean subscribed = subscribePage(pageId);
            if (subscribed) {
                toInsert.add(new Meta_Page_Setting__c(
                    Name = pageId, Page_Id__c = pageId, Page_Name__c = pageName, Active__c = true
                ));
                result.pagesAdded++;
                result.messages.add('Added and subscribed: ' + pageName + ' (' + pageId + ')');
            } else {
                result.pagesSubscribeFailed++;
                result.messages.add('FAILED to subscribe: ' + pageName + ' (' + pageId + ') — check Error_Log__c');
            }
        }
        if (!toInsert.isEmpty()) {
            Database.insert(toInsert, AccessLevel.SYSTEM_MODE);
        }
        return result;
    }

    /**
     * @description GET /me/accounts using the System User token — returns every Page the
     *              token holder has been granted access to in Business Manager.
     */
    private static List<Object> listAccessiblePages() {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:Meta_Graph_API/me/accounts?fields=id,name&limit=200');
        req.setMethod('GET');

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            CreateErrorLog.logFacebookError(
                'listAccessiblePages', 'MetaPageSyncService', 'Page list', new MetaPageSyncException(res.getBody()),
                null, null, null, 'Graph API /me/accounts returned ' + res.getStatusCode()
            );
            return new List<Object>();
        }
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> data = (List<Object>) body.get('data');
        return data != null ? data : new List<Object>();
    }

    /**
     * @description Subscribing a Page to the leadgen field requires that specific Page's own
     *              access token (not the System User token directly) per Meta's API contract
     *              — so this exchanges for it first via GET /{page-id}?fields=access_token.
     */
    private static Boolean subscribePage(String pageId) {
        String pageToken = getPageAccessToken(pageId);
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