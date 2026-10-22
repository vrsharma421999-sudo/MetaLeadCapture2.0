@IsTest
private class MetaOAuthConnectServiceTest {

    // Routes every callout this flow makes: the two oauth/access_token exchanges, /me/accounts,
    // /subscribed_apps, /leadgen_forms, and /{form-id}?fields=questions.
    private class MultiRouteMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            String endpoint = req.getEndpoint();
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');

            if (endpoint.contains('grant_type=fb_exchange_token')) {
                res.setStatusCode(200);
                res.setBody(JSON.serialize(new Map<String, Object>{ 'access_token' => 'long-lived-token', 'expires_in' => 5184000 }));
            } else if (endpoint.contains('oauth/access_token')) {
                res.setStatusCode(200);
                res.setBody(JSON.serialize(new Map<String, Object>{ 'access_token' => 'short-lived-token', 'expires_in' => 3600 }));
            } else if (endpoint.contains('/me/accounts')) {
                res.setStatusCode(200);
                res.setBody(JSON.serialize(new Map<String, Object>{
                    'data' => new List<Object>{
                        new Map<String, Object>{ 'id' => 'PAGE1', 'name' => 'Test Page', 'access_token' => 'page-token-1' }
                    }
                }));
            } else if (endpoint.contains('/subscribed_apps')) {
                res.setStatusCode(200);
                res.setBody('{"success":true}');
            } else if (endpoint.contains('/leadgen_forms')) {
                res.setStatusCode(200);
                res.setBody(JSON.serialize(new Map<String, Object>{
                    'data' => new List<Object>{ new Map<String, Object>{ 'id' => 'FORM1', 'name' => 'Spring Promo Form' } }
                }));
            } else if (endpoint.contains('/FORM1?fields=questions')) {
                res.setStatusCode(200);
                res.setBody(JSON.serialize(new Map<String, Object>{
                    'questions' => new List<Object>{ new Map<String, Object>{ 'key' => 'email', 'label' => 'Email' } }
                }));
            } else {
                res.setStatusCode(404);
                res.setBody('{"error":"unexpected endpoint in test: ' + endpoint + '"}');
            }
            return res;
        }
    }

    @IsTest
    static void testConnect_FullFlow_SavesTokenAndDiscoversPagesAndForms() {
        MetaLeadCaptureSetupController.saveIntegrationSetting(
            new Meta_Integration_Config__c(Meta_App_Id__c = 'APPID1', App_Secret__c = 'shh')
        );
        Test.setMock(HttpCalloutMock.class, new MultiRouteMock());

        Test.startTest();
            MetaOAuthConnectService.ConnectResult result = MetaOAuthConnectService.connect('auth-code-xyz', 'https://example.com/callback');
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assertEquals(1, result.pagesFound);
        System.assertEquals(1, result.pagesAdded);
        System.assertEquals(1, result.formsFound);
        System.assertEquals(1, result.newMappingsAdded);

        Meta_Integration_Config__c saved = Meta_Integration_Config__c.getOrgDefaults();
        System.assertEquals('long-lived-token', saved.Meta_User_Access_Token__c);
        System.assertNotEquals(null, saved.Meta_Token_Expires_At__c);

        Meta_Page_Setting__c pageSetting = [SELECT Page_Id__c, Page_Access_Token__c FROM Meta_Page_Setting__c WHERE Page_Id__c = 'PAGE1' LIMIT 1];
        System.assertEquals('page-token-1', pageSetting.Page_Access_Token__c, 'Page Access Token must be stored automatically');
        System.assertEquals(1, [
            SELECT count() FROM Meta_Field_Map__c WHERE Form_Id__c = 'FORM1' AND Meta_Field_Key__c = 'email'
        ]);
    }

    @IsTest
    static void testConnect_MissingAppIdOrSecret_FailsWithoutCallout() {
        Test.startTest();
            MetaOAuthConnectService.ConnectResult result = MetaOAuthConnectService.connect('auth-code-xyz', 'https://example.com/callback');
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals(0, Limits.getCallouts(), 'must fail fast before making any callout when App Id/Secret are not configured');
    }

    private class OAuthRejectedMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(400);
            res.setBody('{"error":{"message":"Invalid verification code format."}}');
            return res;
        }
    }

    @IsTest
    static void testConnect_FacebookRejectsCode_FailsCleanly() {
        MetaLeadCaptureSetupController.saveIntegrationSetting(
            new Meta_Integration_Config__c(Meta_App_Id__c = 'APPID1', App_Secret__c = 'shh')
        );
        Test.setMock(HttpCalloutMock.class, new OAuthRejectedMock());

        Test.startTest();
            MetaOAuthConnectService.ConnectResult result = MetaOAuthConnectService.connect('bad-code', 'https://example.com/callback');
        Test.stopTest();

        System.assertEquals(false, result.success);
        Meta_Integration_Config__c setting = Meta_Integration_Config__c.getOrgDefaults();
        System.assertEquals(null, setting.Meta_User_Access_Token__c, 'a rejected code must not leave a stale token saved');
    }
}