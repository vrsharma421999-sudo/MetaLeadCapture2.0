@IsTest
private class MetaFormSyncServiceTest {

    // Routes each callout by endpoint substring, since one sync run makes several distinct
    // Graph API calls in sequence (forms-for-page, then questions-for-form, per page/form).
    private class MultiRouteMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            String endpoint = req.getEndpoint();
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');

            if (endpoint.contains('/leadgen_forms')) {
                res.setStatusCode(200);
                res.setBody(JSON.serialize(new Map<String, Object>{
                    'data' => new List<Object>{
                        new Map<String, Object>{ 'id' => 'FORM1', 'name' => 'Spring Promo Form' }
                    }
                }));
            } else if (endpoint.contains('/FORM1?fields=questions')) {
                res.setStatusCode(200);
                res.setBody(JSON.serialize(new Map<String, Object>{
                    'questions' => new List<Object>{
                        new Map<String, Object>{ 'key' => 'email', 'label' => 'Email' },
                        new Map<String, Object>{ 'key' => 'job_title', 'label' => 'Job Title' }
                    }
                }));
            } else {
                res.setStatusCode(404);
                res.setBody('{"error":"unexpected endpoint in test: ' + endpoint + '"}');
            }
            return res;
        }
    }

    @IsTest
    static void testSyncForms_NewQuestionsFound_CreatesInactiveUnmappedRows() {
        insert new Meta_Page_Setting__c(Name = 'PAGE1', Page_Id__c = 'PAGE1', Page_Name__c = 'Test Page', Active__c = true);
        Test.setMock(HttpCalloutMock.class, new MultiRouteMock());

        Test.startTest();
            MetaFormSyncService.SyncResult result = MetaFormSyncService.syncForms();
        Test.stopTest();

        System.assertEquals(1, result.formsFound);
        System.assertEquals(2, result.questionsFound);
        System.assertEquals(2, result.newMappingsAdded);

        List<Meta_Field_Map__c> rows = [
            SELECT Meta_Field_Key__c, Meta_Field_Label__c, Form_Id__c, Form_Name__c, Salesforce_Field_API_Name__c, Active__c
            FROM Meta_Field_Map__c WHERE Form_Id__c = 'FORM1' ORDER BY Meta_Field_Key__c
        ];
        System.assertEquals(2, rows.size());
        System.assertEquals('email', rows[0].Meta_Field_Key__c);
        System.assertEquals('Spring Promo Form', rows[0].Form_Name__c);
        System.assertEquals(null, rows[0].Salesforce_Field_API_Name__c, 'newly discovered rows are unmapped until an admin assigns a field');
        System.assertEquals(false, rows[0].Active__c, 'newly discovered rows start inactive until an admin confirms them');
    }

    @IsTest
    static void testSyncForms_QuestionAlreadyMapped_SkippedNotDuplicated() {
        insert new Meta_Page_Setting__c(Name = 'PAGE1', Page_Id__c = 'PAGE1', Page_Name__c = 'Test Page', Active__c = true);
        insert new Meta_Field_Map__c(
            Name = 'FORM1_email', Form_Id__c = 'FORM1', Meta_Field_Key__c = 'email',
            Salesforce_Field_API_Name__c = 'Email', Active__c = true
        );
        Test.setMock(HttpCalloutMock.class, new MultiRouteMock());

        Test.startTest();
            MetaFormSyncService.SyncResult result = MetaFormSyncService.syncForms();
        Test.stopTest();

        System.assertEquals(1, result.newMappingsAdded, 'only job_title is new — email is already mapped for this form');
        System.assertEquals(1, [
            SELECT count() FROM Meta_Field_Map__c WHERE Form_Id__c = 'FORM1' AND Meta_Field_Key__c = 'email'
        ], 'the already-configured email mapping must not be duplicated');
    }

    @IsTest
    static void testSyncForms_NoActivePages_NoOp() {
        insert new Meta_Page_Setting__c(Name = 'PAGE1', Page_Id__c = 'PAGE1', Page_Name__c = 'Test Page', Active__c = false);
        Test.setMock(HttpCalloutMock.class, new MultiRouteMock());

        Test.startTest();
            MetaFormSyncService.SyncResult result = MetaFormSyncService.syncForms();
        Test.stopTest();

        System.assertEquals(0, result.formsFound, 'inactive pages are not scanned for forms');
        System.assertEquals(0, result.newMappingsAdded);
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
    static void testSyncForms_FormsListFails_ReturnsEmptyWithoutThrowing() {
        insert new Meta_Page_Setting__c(Name = 'PAGE1', Page_Id__c = 'PAGE1', Page_Name__c = 'Test Page', Active__c = true);
        Test.setMock(HttpCalloutMock.class, new ErrorMock());

        Test.startTest();
            MetaFormSyncService.SyncResult result = MetaFormSyncService.syncForms();
        Test.stopTest();

        System.assertEquals(0, result.formsFound);
        System.assertEquals(0, result.newMappingsAdded);
        System.assertEquals(1, [SELECT count() FROM Error_Log__c WHERE Class__c = 'MetaFormSyncService']);
    }
}