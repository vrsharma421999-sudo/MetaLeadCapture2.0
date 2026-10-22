@IsTest
private class MetaPageSyncServiceTest {

    // Routes each callout by endpoint substring, since one sync run makes several distinct
    // Graph API calls in sequence (list accounts, then per-page token fetch + subscribe).
    private class MultiRouteMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            String endpoint = req.getEndpoint();
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');

            if (endpoint.contains('/me/accounts')) {
                res.setStatusCode(200);
                res.setBody(JSON.serialize(new Map<String, Object>{
                    'data' => new List<Object>{
                        new Map<String, Object>{ 'id' => 'NEWPAGE1', 'name' => 'New Page One' },
                        new Map<String, Object>{ 'id' => 'EXISTINGPAGE', 'name' => 'Already Configured' },
                        new Map<String, Object>{ 'id' => 'FAILPAGE', 'name' => 'Will Fail Subscribe' }
                    }
                }));
            } else if (endpoint.contains('/subscribed_apps')) {
                Boolean isFailPage = endpoint.contains('FAILPAGE');
                res.setStatusCode(isFailPage ? 400 : 200);
                res.setBody(isFailPage ? '{"error":{"message":"Insufficient permission"}}' : '{"success":true}');
            } else if (endpoint.contains('fields=access_token')) {
                Boolean isFailPage = endpoint.contains('FAILPAGE');
                res.setStatusCode(isFailPage ? 200 : 200);
                res.setBody(JSON.serialize(new Map<String, Object>{ 'access_token' => 'page-token-xyz' }));
            } else {
                res.setStatusCode(404);
                res.setBody('{"error":"unexpected endpoint in test: ' + endpoint + '"}');
            }
            return res;
        }
    }

    @IsTest
    static void testSyncPages_NewPagesFound_SubscribesAndCreatesRows() {
        insert new Meta_Page_Setting__c(Name = 'EXISTINGPAGE', Page_Id__c = 'EXISTINGPAGE', Page_Name__c = 'Already Configured', Active__c = true);
        Test.setMock(HttpCalloutMock.class, new MultiRouteMock());

        Test.startTest();
            MetaPageSyncService.SyncResult result = MetaPageSyncService.syncPages();
        Test.stopTest();

        System.assertEquals(3, result.pagesFound, 'Mock /me/accounts returns 3 pages');
        System.assertEquals(1, result.pagesAdded, 'Only NEWPAGE1 is new and subscribes successfully');
        System.assertEquals(1, result.pagesSubscribeFailed, 'FAILPAGE fails to subscribe');

        List<Meta_Page_Setting__c> newRow = [SELECT Page_Id__c, Page_Name__c, Page_Access_Token__c, Active__c FROM Meta_Page_Setting__c WHERE Page_Id__c = 'NEWPAGE1'];
        System.assertEquals(1, newRow.size());
        System.assertEquals('New Page One', newRow[0].Page_Name__c);
        System.assertEquals('page-token-xyz', newRow[0].Page_Access_Token__c, 'Page Access Token must be stored automatically');
        System.assertEquals(true, newRow[0].Active__c);

        System.assertEquals(0, [SELECT count() FROM Meta_Page_Setting__c WHERE Page_Id__c = 'FAILPAGE'],
            'A page that fails to subscribe must not get a config row (would otherwise silently look active)');
        System.assertEquals(1, [SELECT count() FROM Meta_Page_Setting__c WHERE Page_Id__c = 'EXISTINGPAGE'],
            'Already-configured pages are left untouched, not duplicated');
    }

    @IsTest
    static void testSyncPages_AllPagesAlreadyConfigured_NoOp() {
        insert new List<Meta_Page_Setting__c>{
            new Meta_Page_Setting__c(Name = 'NEWPAGE1', Page_Id__c = 'NEWPAGE1', Page_Name__c = 'x', Active__c = true),
            new Meta_Page_Setting__c(Name = 'EXISTINGPAGE', Page_Id__c = 'EXISTINGPAGE', Page_Name__c = 'x', Active__c = true),
            new Meta_Page_Setting__c(Name = 'FAILPAGE', Page_Id__c = 'FAILPAGE', Page_Name__c = 'x', Active__c = true)
        };
        Test.setMock(HttpCalloutMock.class, new MultiRouteMock());

        Test.startTest();
            MetaPageSyncService.SyncResult result = MetaPageSyncService.syncPages();
        Test.stopTest();

        System.assertEquals(3, result.pagesFound);
        System.assertEquals(0, result.pagesAdded, 'Every returned page is already configured');
        System.assertEquals(0, result.pagesSubscribeFailed);
    }

    private class ErrorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setBody('{"error":"server error"}');
            return res;
        }
    }

    @IsTest
    static void testSyncPages_AccountsListFails_ReturnsEmptyWithoutThrowing() {
        Test.setMock(HttpCalloutMock.class, new ErrorMock());

        Test.startTest();
            MetaPageSyncService.SyncResult result = MetaPageSyncService.syncPages();
        Test.stopTest();

        System.assertEquals(0, result.pagesFound);
        System.assertEquals(0, result.pagesAdded);
        System.assertEquals(1, [SELECT count() FROM Error_Log__c WHERE Class__c = 'MetaPageSyncService']);
    }
}