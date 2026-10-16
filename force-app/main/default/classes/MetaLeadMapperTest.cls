@IsTest
private class MetaLeadMapperTest {

    @IsTest
    static void testParseCreatedTime_UnixTimestamp_ParsesCorrectly() {
        // The webhook POST payload's created_time shape (raw Unix seconds).
        Datetime result = MetaLeadMapper.parseCreatedTime(1700000000);
        System.assertEquals(Datetime.newInstance((Long) 1700000000 * 1000), result);
    }

    @IsTest
    static void testParseCreatedTime_Iso8601WithPlusOffset_ParsesCorrectly() {
        // The Graph API GET /{leadgen_id} response's created_time shape.
        Datetime result = MetaLeadMapper.parseCreatedTime('2026-09-23T06:16:27+0000');
        System.assertEquals(Datetime.newInstanceGmt(2026, 9, 23, 6, 16, 27), result);
    }

    @IsTest
    static void testParseCreatedTime_Iso8601WithMinusOffset_ParsesCorrectly() {
        Datetime result = MetaLeadMapper.parseCreatedTime('2026-09-23T06:16:27-0500');
        System.assertEquals(Datetime.newInstanceGmt(2026, 9, 23, 6, 16, 27), result,
            'Timezone offset itself is stripped, not converted — matches the existing UTC-assumption behavior of this method');
    }

    @IsTest
    static void testParseCreatedTime_Null_ReturnsNull() {
        System.assertEquals(null, MetaLeadMapper.parseCreatedTime(null));
    }

    @IsTest
    static void testParseCreatedTime_Unparseable_ReturnsNullWithoutThrowing() {
        System.assertEquals(null, MetaLeadMapper.parseCreatedTime('not-a-date'));
    }

    @IsTest
    static void testUpsertLeadFromPayload_FormSpecificMapping_OverridesGlobalForSameKey() {
        MetaLeadMapper.mappingCache = new Map<String, String>{ 'job_title' => 'Description' };
        MetaLeadMapper.formMappingCache = new Map<String, Map<String, String>>{
            'FORM1' => new Map<String, String>{ 'job_title' => 'Title' }
        };

        Map<String, Object> payload = new Map<String, Object>{
            'form_id' => 'FORM1',
            'field_data' => new List<Object>{
                new Map<String, Object>{ 'name' => 'job_title', 'values' => new List<Object>{ 'Engineer' } }
            }
        };

        Test.startTest();
            Lead result = MetaLeadMapper.upsertLeadFromPayload('LG-FORM1', payload);
        Test.stopTest();

        System.assertEquals('Engineer', result.Title,
            'FORM1-specific mapping (job_title -> Title) must win over the global mapping (job_title -> Description)');
    }

    @IsTest
    static void testUpsertLeadFromPayload_NoFormSpecificMapping_FallsBackToGlobal() {
        MetaLeadMapper.mappingCache = new Map<String, String>{ 'job_title' => 'Description' };
        MetaLeadMapper.formMappingCache = new Map<String, Map<String, String>>{
            'FORM1' => new Map<String, String>{ 'phone_number' => 'Phone' } // no job_title override for this form
        };

        Map<String, Object> payload = new Map<String, Object>{
            'form_id' => 'FORM1',
            'field_data' => new List<Object>{
                new Map<String, Object>{ 'name' => 'job_title', 'values' => new List<Object>{ 'Engineer' } }
            }
        };

        Test.startTest();
            Lead result = MetaLeadMapper.upsertLeadFromPayload('LG-FORM2', payload);
        Test.stopTest();

        System.assertEquals('Engineer', result.Description,
            'no FORM1-specific mapping for job_title — must fall back to the global mapping');
    }
}