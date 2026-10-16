@IsTest
private class MetaLeadCaptureSetupControllerTest {

    @IsTest
    static void testIntegrationSetting_NoRowYet_ReturnsBlankDefaultShape() {
        Meta_Integration_Config__c setting = MetaLeadCaptureSetupController.getIntegrationSetting();
        System.assertEquals('Default', setting.Setting_Key__c);
        System.assertEquals(null, setting.Id);
    }

    @IsTest
    static void testSaveIntegrationSetting_UpsertsSingletonByKey() {
        Meta_Integration_Config__c first = MetaLeadCaptureSetupController.saveIntegrationSetting(
            new Meta_Integration_Config__c(Verify_Token__c = 'tok1', Dataset_ID__c = 'DS1')
        );

        Meta_Integration_Config__c second = MetaLeadCaptureSetupController.saveIntegrationSetting(
            new Meta_Integration_Config__c(Verify_Token__c = 'tok2', Dataset_ID__c = 'DS1')
        );

        System.assertEquals(first.Id, second.Id, 'A second save must update the same singleton row, not create a duplicate');
        System.assertEquals(1, [SELECT count() FROM Meta_Integration_Config__c]);
        System.assertEquals('tok2', [SELECT Verify_Token__c FROM Meta_Integration_Config__c LIMIT 1].Verify_Token__c);
    }

    @IsTest
    static void testPageConfig_SaveListDelete_RoundTrips() {
        Meta_Page_Setting__c saved = MetaLeadCaptureSetupController.savePageConfig(
            new Meta_Page_Setting__c(Name = 'PAGE1', Page_Id__c = 'PAGE1', Page_Name__c = 'Main Page', Active__c = true)
        );
        List<Meta_Page_Setting__c> configs = MetaLeadCaptureSetupController.getPageConfigs();
        System.assertEquals(1, configs.size());
        System.assertEquals('PAGE1', configs[0].Page_Id__c);

        MetaLeadCaptureSetupController.deletePageConfig(saved.Id);
        System.assertEquals(0, MetaLeadCaptureSetupController.getPageConfigs().size());
    }

    @IsTest
    static void testFieldMapping_SaveListDelete_RoundTrips() {
        Meta_Field_Map__c saved = MetaLeadCaptureSetupController.saveFieldMapping(
            new Meta_Field_Map__c(Name = 'Email', Meta_Field_Key__c = 'email', Salesforce_Field_API_Name__c = 'Email', Active__c = true)
        );
        List<Meta_Field_Map__c> mappings = MetaLeadCaptureSetupController.getFieldMappings();
        System.assertEquals(1, mappings.size());

        MetaLeadCaptureSetupController.deleteFieldMapping(saved.Id);
        System.assertEquals(0, MetaLeadCaptureSetupController.getFieldMappings().size());
    }

    private class EmptyAccountsMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"data":[]}');
            return res;
        }
    }

    @IsTest
    static void testSyncPagesFromMeta_DelegatesToMetaPageSyncService() {
        Test.setMock(HttpCalloutMock.class, new EmptyAccountsMock());

        Test.startTest();
            MetaPageSyncService.SyncResult result = MetaLeadCaptureSetupController.syncPagesFromMeta();
        Test.stopTest();

        System.assertEquals(0, result.pagesFound, 'Mock returns zero pages; asserts the call reaches MetaPageSyncService without throwing');
    }

    @IsTest
    static void testSyncFormsFromMeta_DelegatesToMetaFormSyncService() {
        // No active Meta_Page_Setting__c rows exist in this test — MetaFormSyncService scans
        // zero pages and makes no callouts, so no mock is needed; this just asserts the
        // delegation itself doesn't throw.
        Test.startTest();
            MetaFormSyncService.SyncResult result = MetaLeadCaptureSetupController.syncFormsFromMeta();
        Test.stopTest();

        System.assertEquals(0, result.formsFound);
    }

    private class SingleFormMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            String endpoint = req.getEndpoint();
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            if (endpoint.contains('/leadgen_forms')) {
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
                res.setBody('{"error":"unexpected endpoint: ' + endpoint + '"}');
            }
            return res;
        }
    }

    @IsTest
    static void testGetAvailableForms_DelegatesToMetaFormSyncService() {
        insert new Meta_Page_Setting__c(Name = 'PAGE1', Page_Id__c = 'PAGE1', Page_Name__c = 'Test Page', Active__c = true);
        Test.setMock(HttpCalloutMock.class, new SingleFormMock());

        Test.startTest();
            List<MetaFormSyncService.FormOption> forms = MetaLeadCaptureSetupController.getAvailableForms();
        Test.stopTest();

        System.assertEquals(1, forms.size());
        System.assertEquals('FORM1', forms[0].formId);
        System.assertEquals('Spring Promo Form', forms[0].formName);
    }

    @IsTest
    static void testGetFormQuestions_DelegatesToMetaFormSyncService() {
        Test.setMock(HttpCalloutMock.class, new SingleFormMock());

        Test.startTest();
            List<MetaFormSyncService.QuestionOption> questions = MetaLeadCaptureSetupController.getFormQuestions('FORM1');
        Test.stopTest();

        System.assertEquals(1, questions.size());
        System.assertEquals('email', questions[0].key);
        System.assertEquals('Email', questions[0].label);
    }

    @IsTest
    static void testFieldMapping_FormScopedAndGlobalRows_NameDerivedDifferently() {
        Meta_Field_Map__c globalRow = MetaLeadCaptureSetupController.saveFieldMapping(
            new Meta_Field_Map__c(Meta_Field_Key__c = 'email', Salesforce_Field_API_Name__c = 'Email', Active__c = true)
        );
        Meta_Field_Map__c formRow = MetaLeadCaptureSetupController.saveFieldMapping(
            new Meta_Field_Map__c(Form_Id__c = 'FORM1', Meta_Field_Key__c = 'email', Salesforce_Field_API_Name__c = 'Description', Active__c = true)
        );

        System.assertEquals('email', globalRow.Name, 'a blank Form_Id__c keeps the original global-only Name shape');
        System.assertEquals('FORM1_email', formRow.Name, 'a populated Form_Id__c must be folded into Name so it does not collide with the global row');
        System.assertEquals(2, [SELECT count() FROM Meta_Field_Map__c], 'both rows must coexist — same Meta_Field_Key__c, different scope');
    }

    @IsTest
    static void testGetLeadFieldOptions_IncludesKnownWritableField() {
        List<MetaLeadCaptureSetupController.PicklistOption> options = MetaLeadCaptureSetupController.getLeadFieldOptions();
        Boolean foundEmail = false;
        for (MetaLeadCaptureSetupController.PicklistOption opt : options) {
            if (opt.value == 'Email') {
                foundEmail = true;
            }
        }
        System.assertEquals(true, foundEmail, 'Lead.Email is a standard writable field and must appear in the options');
    }

    @IsTest
    static void testStageMapping_SaveListDelete_RoundTrips() {
        Meta_Lead_Stage_Mapping__c saved = MetaLeadCaptureSetupController.saveStageMapping(
            new Meta_Lead_Stage_Mapping__c(Salesforce_Status__c = 'Closed - Converted', Meta_Event_Name__c = 'conversion', Active__c = true)
        );
        List<Meta_Lead_Stage_Mapping__c> mappings = MetaLeadCaptureSetupController.getStageMappings();
        System.assertEquals(1, mappings.size());

        MetaLeadCaptureSetupController.deleteStageMapping(saved.Id);
        System.assertEquals(0, MetaLeadCaptureSetupController.getStageMappings().size());
    }

    @IsTest
    static void testGetLeadStatusOptions_ReturnsActivePicklistValues() {
        List<MetaLeadCaptureSetupController.PicklistOption> options = MetaLeadCaptureSetupController.getLeadStatusOptions();
        System.assert(!options.isEmpty(), 'Lead.Status always ships with at least the standard values');
    }

    private static User createTestUser(String alias) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        return new User(
            FirstName = 'Setup', LastName = 'Test ' + alias, Alias = alias,
            Email = alias + '.setup.test@example.com', Username = alias + '.setup.test@example.com.' + DateTime.now().getTime(),
            TimeZoneSidKey = 'America/Los_Angeles', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US', ProfileId = p.Id
        );
    }

    @IsTest
    static void testNotificationRecipient_SaveListDelete_RoundTrips() {
        User u = createTestUser('recip');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
        }

        MetaLeadCaptureSetupController.saveNotificationRecipient(null, u.Id, 'Both', true);
        List<MetaLeadCaptureSetupController.NotificationRecipientRow> rows = MetaLeadCaptureSetupController.getNotificationRecipients();
        System.assertEquals(1, rows.size());
        System.assertEquals('Both', rows[0].channel);
        System.assertEquals(u.Id, rows[0].userId);

        MetaLeadCaptureSetupController.deleteNotificationRecipient(rows[0].id);
        System.assertEquals(0, MetaLeadCaptureSetupController.getNotificationRecipients().size());
    }

    @IsTest
    static void testSearchUsers_MatchesByNameOrEmail() {
        User u = createTestUser('search');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
        }

        List<MetaLeadCaptureSetupController.UserOption> results = MetaLeadCaptureSetupController.searchUsers('search.setup.test');
        System.assert(!results.isEmpty(), 'Search by email fragment must find the user');
    }

    @IsTest
    static void testGetSyncFailures_ExcludesResolved() {
        insert new List<Meta_Lead_Sync_Failure__c>{
            new Meta_Lead_Sync_Failure__c(Leadgen_Id__c = 'LG-1', Status__c = 'New'),
            new Meta_Lead_Sync_Failure__c(Leadgen_Id__c = 'LG-2', Status__c = 'Resolved')
        };

        List<Meta_Lead_Sync_Failure__c> open = MetaLeadCaptureSetupController.getSyncFailures();
        System.assertEquals(1, open.size());
        System.assertEquals('LG-1', open[0].Leadgen_Id__c);
    }

    @IsTest
    static void testResendFailures_UnknownId_ReturnsFailureOutcomeWithoutThrowing() {
        Meta_Lead_Sync_Failure__c failure = new Meta_Lead_Sync_Failure__c(Leadgen_Id__c = 'LG-3', Status__c = 'New');
        insert failure;
        Id realId = failure.Id;
        delete failure;

        List<MetaLeadCaptureSetupController.ResendOutcome> outcomes = MetaLeadCaptureSetupController.resendFailures(new List<Id>{ realId });
        System.assertEquals(1, outcomes.size());
        System.assertEquals(false, outcomes[0].success);
    }
}