@IsTest
private class LeadConversionSyncHandlerTest {

    @IsTest
    static void testStatusChange_MetaSourcedLead_QueuesMappedConversionEvent() {
        LeadConversionSyncHandler.stageMappingCache = new Map<String, String>{ 'Working - Contacted' => 'qualified_lead' };

        Lead lead = new Lead(
            FirstName = 'Test', LastName = 'Lead', Company = 'Co',
            Status = 'Open - Not Contacted', Meta_Leadgen_Id__c = 'LG-100'
        );
        insert lead;

        Test.startTest();
            lead.Status = 'Working - Contacted';
            update lead;
        Test.stopTest();

        List<Meta_Conversion_Event__c> events = [
            SELECT Lead__c, Leadgen_Id__c, Event_Name__c, Status__c
            FROM Meta_Conversion_Event__c
            WHERE Lead__c = :lead.Id
        ];
        System.assertEquals(1, events.size());
        System.assertEquals('LG-100', events[0].Leadgen_Id__c);
        System.assertEquals('qualified_lead', events[0].Event_Name__c);
        System.assertEquals('Pending', events[0].Status__c);
    }

    @IsTest
    static void testStatusChange_NonMetaLead_NoEventQueued() {
        Lead lead = new Lead(FirstName = 'Test', LastName = 'Lead', Company = 'Co', Status = 'Open - Not Contacted');
        insert lead;

        Test.startTest();
            lead.Status = 'Working - Contacted';
            update lead;
        Test.stopTest();

        System.assertEquals(0, [SELECT count() FROM Meta_Conversion_Event__c WHERE Lead__c = :lead.Id]);
    }

    @IsTest
    static void testStatusChange_NoActiveMapping_NoEventQueued() {
        LeadConversionSyncHandler.stageMappingCache = new Map<String, String>();

        Lead lead = new Lead(
            FirstName = 'Test', LastName = 'Lead', Company = 'Co',
            Status = 'Open - Not Contacted', Meta_Leadgen_Id__c = 'LG-101'
        );
        insert lead;

        Test.startTest();
            lead.Status = 'Working - Contacted';
            update lead;
        Test.stopTest();

        System.assertEquals(0, [SELECT count() FROM Meta_Conversion_Event__c WHERE Lead__c = :lead.Id]);
    }

    @IsTest
    static void testStatusUnchanged_NoEventQueued() {
        Lead lead = new Lead(
            FirstName = 'Test', LastName = 'Lead', Company = 'Co',
            Status = 'Open - Not Contacted', Meta_Leadgen_Id__c = 'LG-102'
        );
        insert lead;

        Test.startTest();
            lead.City = 'Some City';
            update lead;
        Test.stopTest();

        System.assertEquals(0, [SELECT count() FROM Meta_Conversion_Event__c WHERE Lead__c = :lead.Id]);
    }

    @IsTest
    static void testStatusChange_Bulk_OneEventPerLead() {
        LeadConversionSyncHandler.stageMappingCache = new Map<String, String>{ 'Closed - Not Converted' => 'disqualified_lead' };

        List<Lead> leads = new List<Lead>();
        for (Integer i = 0; i < 20; i++) {
            leads.add(new Lead(
                FirstName = 'Bulk', LastName = 'Lead' + i, Company = 'Co',
                Status = 'Open - Not Contacted', Meta_Leadgen_Id__c = 'LG-BULK-' + i
            ));
        }
        insert leads;

        Test.startTest();
            // 'Closed - Converted' can only be reached via Database.convertLead (Salesforce
            // rejects setting a converted-type Status through plain DML), so this uses the
            // other closed status to exercise the bulk/mapping path without that detour.
            for (Lead l : leads) {
                l.Status = 'Closed - Not Converted';
            }
            update leads;
        Test.stopTest();

        System.assertEquals(20, [SELECT count() FROM Meta_Conversion_Event__c WHERE Event_Name__c = 'disqualified_lead']);
    }
}