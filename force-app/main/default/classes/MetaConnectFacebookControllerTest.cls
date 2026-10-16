@IsTest
private class MetaConnectFacebookControllerTest {

    @IsTest
    static void testConstructor_ReadsOriginParamAndIntegrationSetting() {
        MetaLeadCaptureSetupController.saveIntegrationSetting(
            new Meta_Integration_Config__c(Meta_App_Id__c = 'APPID1', Meta_App_Login_Config_Id__c = 'CFG1')
        );

        Test.setCurrentPageReference(new PageReference('/apex/MetaConnectFacebook'));
        ApexPages.currentPage().getParameters().put('origin', 'https://example.my.salesforce.com');

        Test.startTest();
            MetaConnectFacebookController controller = new MetaConnectFacebookController();
        Test.stopTest();

        System.assertEquals('https://example.my.salesforce.com', controller.originParam);
        System.assertEquals('APPID1', controller.appId);
        System.assertEquals('CFG1', controller.configId);
    }

    @IsTest
    static void testConstructor_NoIntegrationSettingYet_NullsWithoutThrowing() {
        Test.setCurrentPageReference(new PageReference('/apex/MetaConnectFacebook'));

        Test.startTest();
            MetaConnectFacebookController controller = new MetaConnectFacebookController();
        Test.stopTest();

        System.assertEquals(null, controller.appId);
        System.assertEquals(null, controller.configId);
    }
}