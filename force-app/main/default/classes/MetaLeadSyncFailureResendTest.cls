@IsTest
private class MetaLeadSyncFailureResendTest {

    private class GraphApiMock implements HttpCalloutMock {
        private Integer statusCode;
        private String body;
        GraphApiMock(Integer statusCode, String body) {
            this.statusCode = statusCode;
            this.body = body;
        }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            res.setBody(body);
            return res;
        }
    }

    private static String buildLeadPayload(String fullName, String email) {
        Map<String, Object> payload = new Map<String, Object>{
            'page_id' => 'PAGE1',
            'field_data' => new List<Object>{
                new Map<String, Object>{ 'name' => 'full_name', 'values' => new List<Object>{ fullName } },
                new Map<String, Object>{ 'name' => 'email', 'values' => new List<Object>{ email } }
            }
        };
        return JSON.serialize(payload);
    }

    @IsTest
    static void testResend_StoredPayload_ResolvesAndLinksLead() {
        // Meta_Lead_Field_Mapping__c is org data (not deployed metadata like the old
        // __mdt), so it isn't visible inside an isolated test transaction — inject it
        // directly via MetaLeadMapper's @TestVisible cache instead of relying on org rows.
        MetaLeadMapper.mappingCache = new Map<String, String>{ 'email' => 'Email' };

        Meta_Lead_Sync_Failure__c failure = new Meta_Lead_Sync_Failure__c(
            Leadgen_Id__c = 'LG-1',
            Page_Id__c = 'PAGE1',
            Raw_Payload__c = buildLeadPayload('Resend Person', 'resend@example.com'),
            Failure_Reason__c = 'original failure',
            Status__c = 'New',
            Attempts__c = 1
        );
        insert failure;

        Test.startTest();
            List<MetaLeadSyncFailureResend.ResendResult> results =
                MetaLeadSyncFailureResend.resend(new List<Id>{ failure.Id });
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(true, results[0].success);

        Meta_Lead_Sync_Failure__c updated = [
            SELECT Status__c, Resolved_Lead__c, Attempts__c FROM Meta_Lead_Sync_Failure__c WHERE Id = :failure.Id
        ];
        System.assertEquals('Resolved', updated.Status__c);
        System.assertNotEquals(null, updated.Resolved_Lead__c);
        System.assertEquals(2, updated.Attempts__c);

        Lead resolved = [SELECT Email, Meta_Leadgen_Id__c FROM Lead WHERE Id = :updated.Resolved_Lead__c];
        System.assertEquals('resend@example.com', resolved.Email);
        System.assertEquals('LG-1', resolved.Meta_Leadgen_Id__c);
    }

    @IsTest
    static void testResend_NoStoredPayload_RefetchesFromGraphApi() {
        MetaLeadFetchQueueable.pageConfigCache = new Map<String, Meta_Page_Setting__c>{
            'PAGE1' => new Meta_Page_Setting__c(Page_Id__c = 'PAGE1', Active__c = true)
        };
        MetaLeadMapper.mappingCache = new Map<String, String>{ 'email' => 'Email' };
        Test.setMock(HttpCalloutMock.class, new GraphApiMock(200, buildLeadPayload('Refetched Person', 'refetch@example.com')));

        Meta_Lead_Sync_Failure__c failure = new Meta_Lead_Sync_Failure__c(
            Leadgen_Id__c = 'LG-2',
            Page_Id__c = 'PAGE1',
            Raw_Payload__c = null,
            Failure_Reason__c = 'Page config was missing at delivery time',
            Status__c = 'New',
            Attempts__c = 1
        );
        insert failure;

        Test.startTest();
            List<MetaLeadSyncFailureResend.ResendResult> results =
                MetaLeadSyncFailureResend.resend(new List<Id>{ failure.Id });
        Test.stopTest();

        System.assertEquals(true, results[0].success);
        Lead resolved = [SELECT Email FROM Lead WHERE Meta_Leadgen_Id__c = 'LG-2'];
        System.assertEquals('refetch@example.com', resolved.Email);
    }

    @IsTest
    static void testResend_StillFailing_KeepsRetryingAndIncrementsAttempts() {
        // No Page config primed, and no stored payload — the re-fetch attempt fails closed.
        Meta_Lead_Sync_Failure__c failure = new Meta_Lead_Sync_Failure__c(
            Leadgen_Id__c = 'LG-3',
            Page_Id__c = 'STILL_UNCONFIGURED',
            Raw_Payload__c = null,
            Status__c = 'New',
            Attempts__c = 2
        );
        insert failure;

        Test.startTest();
            List<MetaLeadSyncFailureResend.ResendResult> results =
                MetaLeadSyncFailureResend.resend(new List<Id>{ failure.Id });
        Test.stopTest();

        System.assertEquals(false, results[0].success);
        Meta_Lead_Sync_Failure__c updated = [
            SELECT Status__c, Attempts__c FROM Meta_Lead_Sync_Failure__c WHERE Id = :failure.Id
        ];
        System.assertEquals('Retrying', updated.Status__c);
        System.assertEquals(3, updated.Attempts__c);
    }

    @IsTest
    static void testResend_UnknownId_ReturnsFailureResultWithoutThrowing() {
        Meta_Lead_Sync_Failure__c failure = new Meta_Lead_Sync_Failure__c(Leadgen_Id__c = 'LG-4', Status__c = 'New');
        insert failure;
        Id realId = failure.Id;
        delete failure;

        Test.startTest();
            List<MetaLeadSyncFailureResend.ResendResult> results =
                MetaLeadSyncFailureResend.resend(new List<Id>{ realId });
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(false, results[0].success);
    }

    @IsTest
    static void testResend_EmptyInput_NoOp() {
        Test.startTest();
            System.assertEquals(0, MetaLeadSyncFailureResend.resend(new List<Id>()).size());
            System.assertEquals(0, MetaLeadSyncFailureResend.resend(null).size());
        Test.stopTest();
    }
}