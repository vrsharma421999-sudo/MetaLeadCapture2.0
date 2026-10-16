@IsTest
private class CreateErrorLogTest {

    @IsTest
    static void testLogFacebookError_PopulatesFacebookFields() {
        Test.startTest();
            CreateErrorLog.logFacebookError(
                'someMethod', 'SomeClass', 'Lead leadgen_id=123',
                new TestException('boom'),
                'PAGE1', 'CAMP1', 'Mumbai', 'raw payload details'
            );
        Test.stopTest();

        Error_Log__c log = [
            SELECT Method__c, Class__c, Object__c, Facebook_error__c, Facebook_Page__c,
                   Facebook_Campaign__c, Facebook_Location__c, Facebook_Detailed_Information__c
            FROM Error_Log__c
            WHERE Class__c = 'SomeClass'
        ];
        System.assertEquals('someMethod', log.Method__c);
        System.assertEquals('Lead leadgen_id=123', log.Object__c);
        System.assertEquals(true, log.Facebook_error__c);
        System.assertEquals('PAGE1', log.Facebook_Page__c);
        System.assertEquals('CAMP1', log.Facebook_Campaign__c);
        System.assertEquals('Mumbai', log.Facebook_Location__c);
        System.assertEquals('raw payload details', log.Facebook_Detailed_Information__c);
    }

    public class TestException extends Exception {}
}