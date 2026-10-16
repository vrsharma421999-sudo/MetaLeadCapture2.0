@IsTest
private class MetaLeadWebhookTest {

    private static final String SECRET = 'test-app-secret-123';
    private static final String VERIFY_TOKEN = 'test-verify-token-456';

    private static void primeSettings() {
        MetaLeadWebhook.cachedSetting = new Meta_Integration_Config__c(
            Verify_Token__c = VERIFY_TOKEN,
            App_Secret__c = SECRET
        );
    }

    private static String sign(String body) {
        Blob mac = Crypto.generateMac('hmacSHA256', Blob.valueOf(body), Blob.valueOf(SECRET));
        return 'sha256=' + EncodingUtil.convertToHex(mac);
    }

    // =====================================================================
    // GET — subscription verification handshake
    // =====================================================================
    @IsTest
    static void testDoGet_ValidHandshake_ReturnsChallenge() {
        primeSettings();

        RestRequest req = new RestRequest();
        req.requestUri = 'https://example.com/services/apexrest/MetaLeadWebhook/';
        req.httpMethod = 'GET';
        req.params.put('hub.mode', 'subscribe');
        req.params.put('hub.verify_token', VERIFY_TOKEN);
        req.params.put('hub.challenge', 'challenge-xyz');
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
            MetaLeadWebhook.doGet();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('challenge-xyz', RestContext.response.responseBody.toString());
    }

    @IsTest
    static void testDoGet_WrongVerifyToken_Returns403() {
        primeSettings();

        RestRequest req = new RestRequest();
        req.requestUri = 'https://example.com/services/apexrest/MetaLeadWebhook/';
        req.httpMethod = 'GET';
        req.params.put('hub.mode', 'subscribe');
        req.params.put('hub.verify_token', 'wrong-token');
        req.params.put('hub.challenge', 'challenge-xyz');
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
            MetaLeadWebhook.doGet();
        Test.stopTest();

        System.assertEquals(403, RestContext.response.statusCode);
    }

    @IsTest
    static void testDoGet_NoSettingConfigured_Returns403() {
        // cachedSetting left null and no Meta_Integration_Setting__c row exists in this test
        // context, so this must fail closed.
        RestRequest req = new RestRequest();
        req.requestUri = 'https://example.com/services/apexrest/MetaLeadWebhook/';
        req.httpMethod = 'GET';
        req.params.put('hub.mode', 'subscribe');
        req.params.put('hub.verify_token', 'anything');
        req.params.put('hub.challenge', 'challenge-xyz');
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
            MetaLeadWebhook.doGet();
        Test.stopTest();

        System.assertEquals(403, RestContext.response.statusCode);
    }

    // =====================================================================
    // POST — signature verification
    // =====================================================================
    @IsTest
    static void testDoPost_ValidSignature_AcksEvent() {
        primeSettings();
        String body = '{"entry":[{"changes":[{"field":"leadgen","value":{"leadgen_id":"999888777"}}]}]}';

        RestRequest req = new RestRequest();
        req.requestUri = 'https://example.com/services/apexrest/MetaLeadWebhook/';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(body);
        req.headers.put('X-Hub-Signature-256', sign(body));
        RestContext.request = req;
        RestContext.response = new RestResponse();

        // Intentionally not wrapped in Test.startTest()/stopTest() so the enqueued
        // MetaLeadFetchQueueable does not actually execute (and attempt a live callout)
        // as part of this test — that logic is covered by MetaLeadFetchQueueableTest.
        MetaLeadWebhook.doPost();

        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('EVENT_RECEIVED', RestContext.response.responseBody.toString());
    }

    @IsTest
    static void testDoPost_LowercaseSignatureHeader_AcksEvent() {
        primeSettings();
        String body = '{"entry":[{"changes":[{"field":"leadgen","value":{"leadgen_id":"999888777"}}]}]}';

        RestRequest req = new RestRequest();
        req.requestUri = 'https://example.com/services/apexrest/MetaLeadWebhook/';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(body);
        req.headers.put('x-hub-signature-256', sign(body));
        RestContext.request = req;
        RestContext.response = new RestResponse();

        MetaLeadWebhook.doPost();

        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('EVENT_RECEIVED', RestContext.response.responseBody.toString());
    }

    @IsTest
    static void testDoPost_MissingSignature_Returns403AndLogsError() {
        primeSettings();
        String body = '{"entry":[{"changes":[{"field":"leadgen","value":{"leadgen_id":"1"}}]}]}';

        RestRequest req = new RestRequest();
        req.requestUri = 'https://example.com/services/apexrest/MetaLeadWebhook/';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(body);
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
            MetaLeadWebhook.doPost();
        Test.stopTest();

        System.assertEquals(403, RestContext.response.statusCode);
        List<Error_Log__c> logs = [SELECT Id, Facebook_error__c FROM Error_Log__c WHERE Class__c = 'MetaLeadWebhook'];
        System.assertEquals(1, logs.size());
        System.assertEquals(true, logs[0].Facebook_error__c);
    }

    @IsTest
    static void testDoPost_TamperedBody_Returns403() {
        primeSettings();
        String signedBody = '{"entry":[{"changes":[{"field":"leadgen","value":{"leadgen_id":"1"}}]}]}';
        String tamperedBody = '{"entry":[{"changes":[{"field":"leadgen","value":{"leadgen_id":"2"}}]}]}';

        RestRequest req = new RestRequest();
        req.requestUri = 'https://example.com/services/apexrest/MetaLeadWebhook/';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(tamperedBody);
        req.headers.put('X-Hub-Signature-256', sign(signedBody));
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
            MetaLeadWebhook.doPost();
        Test.stopTest();

        System.assertEquals(403, RestContext.response.statusCode);
    }

    @IsTest
    static void testDoPost_MalformedJson_Returns200AndLogsError() {
        primeSettings();
        String body = 'not-json{{{';

        RestRequest req = new RestRequest();
        req.requestUri = 'https://example.com/services/apexrest/MetaLeadWebhook/';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(body);
        req.headers.put('X-Hub-Signature-256', sign(body));
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
            MetaLeadWebhook.doPost();
        Test.stopTest();

        // Ack 200 regardless, so Meta doesn't retry a payload we can never parse.
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('EVENT_RECEIVED', RestContext.response.responseBody.toString());
        List<Error_Log__c> logs = [SELECT Id FROM Error_Log__c WHERE Class__c = 'MetaLeadWebhook'];
        System.assertEquals(1, logs.size());
    }

    @IsTest
    static void testDoPost_NoLeadgenChanges_Returns200NoOp() {
        primeSettings();
        String body = '{"entry":[{"changes":[{"field":"some_other_field","value":{}}]}]}';

        RestRequest req = new RestRequest();
        req.requestUri = 'https://example.com/services/apexrest/MetaLeadWebhook/';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(body);
        req.headers.put('X-Hub-Signature-256', sign(body));
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
            MetaLeadWebhook.doPost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(0, [SELECT count() FROM AsyncApexJob WHERE ApexClass.Name = 'MetaLeadFetchQueueable']);
    }
}