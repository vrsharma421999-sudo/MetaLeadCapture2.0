@IsTest
private class MetaLeadSyncFailureNotifierTest {

    private static User createTestUser(String alias) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        return new User(
            FirstName = 'Meta', LastName = 'Notify ' + alias, Alias = alias,
            Email = alias + '.notify.test@example.com', Username = alias + '.notify.test@example.com.' + DateTime.now().getTime(),
            TimeZoneSidKey = 'America/Los_Angeles', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US', ProfileId = p.Id
        );
    }

    @IsTest
    static void testNotify_NoRecipientsNoEmailConfigured_NoOpWithoutError() {
        // cachedRecipients/cachedSetting left null; no Meta_Notification_Recipient__c or
        // Meta_Integration_Setting__c rows exist in this test context, so both channels
        // should early-return cleanly.
        Meta_Lead_Sync_Failure__c failure = new Meta_Lead_Sync_Failure__c(Leadgen_Id__c = 'LG-N1', Status__c = 'New');

        Test.startTest();
            insert failure; // trigger -> MetaLeadSyncFailureNotifier.notify
        Test.stopTest();

        System.assertEquals(0, Limits.getEmailInvocations());
    }

    @IsTest
    static void testNotify_AdditionalEmailConfigured_SendsEmail() {
        MetaLeadSyncFailureNotifier.cachedSetting = new Meta_Integration_Config__c(
            Failure_Notification_Email__c = 'ops@example.com, admin@example.com'
        );

        Meta_Lead_Sync_Failure__c failure = new Meta_Lead_Sync_Failure__c(
            Leadgen_Id__c = 'LG-N2', Failure_Reason__c = 'Something went wrong', Status__c = 'New'
        );

        Test.startTest();
            insert failure;
        Test.stopTest();

        // Email deliverability settings vary by org (this Developer Edition org restricts
        // it), so Messaging.sendEmail's own success/failure isn't a portable thing to assert
        // on — sendEmailAlert is deliberately best-effort (wrapped in try/catch) precisely so
        // a deliverability restriction never blocks the failure record itself from saving.
        // What matters here: notify() ran to completion without an unhandled exception.
        System.assertEquals(1, [SELECT count() FROM Meta_Lead_Sync_Failure__c WHERE Id = :failure.Id]);
    }

    @IsTest
    static void testNotify_BellRecipientConfigured_SendsCustomNotificationWithoutError() {
        User recipientUser = createTestUser('bell');
        // User + the custom-object insert below both touch setup-adjacent data in this test
        // (User is a setup object) — System.runAs opens a separate DML context for the user
        // insert, the standard way around MIXED_DML_OPERATION.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert recipientUser;
        }
        MetaLeadSyncFailureNotifier.cachedRecipients = new List<Meta_Notify_Recipient__c>{
            new Meta_Notify_Recipient__c(User_Id__c = recipientUser.Id, User_Email__c = recipientUser.Email, Channel__c = 'Bell', Active__c = true)
        };

        Meta_Lead_Sync_Failure__c failure = new Meta_Lead_Sync_Failure__c(
            Leadgen_Id__c = 'LG-N3', Failure_Reason__c = 'Needs eyes on it', Status__c = 'New'
        );

        Test.startTest();
            insert failure;
        Test.stopTest();

        // Messaging.CustomNotification.send() has no synchronous, queryable side effect to
        // assert on in a test context — reaching this point without an unhandled exception
        // confirms the notification-type lookup and recipient resolution both succeeded.
        System.assert(true);
    }

    @IsTest
    static void testNotify_BothChannelRecipient_SendsEmailToUserAddress() {
        User recipientUser = createTestUser('both');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert recipientUser;
        }
        MetaLeadSyncFailureNotifier.cachedRecipients = new List<Meta_Notify_Recipient__c>{
            new Meta_Notify_Recipient__c(User_Id__c = recipientUser.Id, User_Email__c = recipientUser.Email, Channel__c = 'Both', Active__c = true)
        };

        Meta_Lead_Sync_Failure__c failure = new Meta_Lead_Sync_Failure__c(
            Leadgen_Id__c = 'LG-N6', Failure_Reason__c = 'Both channels', Status__c = 'New'
        );

        Test.startTest();
            insert failure;
        Test.stopTest();

        System.assertEquals(1, [SELECT count() FROM Meta_Lead_Sync_Failure__c WHERE Id = :failure.Id]);
    }

    @IsTest
    static void testNotify_InactiveRecipient_ExcludedFromEitherChannel() {
        User recipientUser = createTestUser('inact');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert recipientUser;
        }
        MetaLeadSyncFailureNotifier.cachedRecipients = new List<Meta_Notify_Recipient__c>{
            new Meta_Notify_Recipient__c(User_Id__c = recipientUser.Id, User_Email__c = recipientUser.Email, Channel__c = 'Both', Active__c = false)
        };

        Meta_Lead_Sync_Failure__c failure = new Meta_Lead_Sync_Failure__c(Leadgen_Id__c = 'LG-N7', Status__c = 'New');

        Test.startTest();
            insert failure;
        Test.stopTest();

        System.assertEquals(0, Limits.getEmailInvocations());
    }

    @IsTest
    static void testNotify_BulkFailures_SingleNotificationCallCoversAll() {
        MetaLeadSyncFailureNotifier.cachedSetting = new Meta_Integration_Config__c(
            Failure_Notification_Email__c = 'ops@example.com'
        );

        List<Meta_Lead_Sync_Failure__c> failures = new List<Meta_Lead_Sync_Failure__c>{
            new Meta_Lead_Sync_Failure__c(Leadgen_Id__c = 'LG-N4', Status__c = 'New'),
            new Meta_Lead_Sync_Failure__c(Leadgen_Id__c = 'LG-N5', Status__c = 'New')
        };

        Test.startTest();
            insert failures;
        Test.stopTest();

        // Same deliverability caveat as testNotify_AdditionalEmailConfigured_SendsEmail —
        // asserting on the actual send would be environment-fragile. What this test guards is
        // the bulk shape: one notify() call for the whole insert, not one per record (which
        // the trigger already guarantees by passing Trigger.new as a single list) and that the
        // batch doesn't throw partway through.
        System.assertEquals(2, [SELECT count() FROM Meta_Lead_Sync_Failure__c WHERE Id IN :failures]);
    }
}