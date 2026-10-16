public without sharing class CreateErrorLog {
	public static void logError(String methodName, String className, String objectName, Exception e) {
        try {
            Error_Log__c errorLog = new Error_Log__c(
                Current_User__c = UserInfo.getUserId(),
                Method__c = methodName,
                Class__c = className,
                Object__c = objectName,
                Datetime__c = System.now(),
                Description__c = e.getMessage() + ' (' + e.getTypeName() + ')'
            );
            Database.insert(errorLog, AccessLevel.SYSTEM_MODE);
        } catch (Exception ex) {
            System.debug('Failed to log error: ' + ex.getMessage());
        }
    }

    /**
     * @description Same as logError, but also populates Error_Log__c's Facebook_* fields
     *              (Facebook_error__c, Facebook_Page__c, Facebook_Campaign__c,
     *              Facebook_Location__c, Facebook_Detailed_Information__c) for failures
     *              from the Meta Lead Ads integration (MetaLeadWebhook / MetaLeadFetchQueueable).
     */
    public static void logFacebookError(String methodName, String className, String objectName, Exception e,
            String facebookPage, String facebookCampaign, String facebookLocation, String detailedInformation) {
        try {
            Error_Log__c errorLog = new Error_Log__c(
                Current_User__c = UserInfo.getUserId(),
                Method__c = methodName,
                Class__c = className,
                Object__c = objectName,
                Datetime__c = System.now(),
                Description__c = e.getMessage() + ' (' + e.getTypeName() + ')',
                Facebook_error__c = true,
                Facebook_Page__c = facebookPage,
                Facebook_Campaign__c = facebookCampaign,
                Facebook_Location__c = facebookLocation,
                Facebook_Detailed_Information__c = detailedInformation
            );
            Database.insert(errorLog, AccessLevel.SYSTEM_MODE);
        } catch (Exception ex) {
            System.debug('Failed to log Facebook error: ' + ex.getMessage());
        }
    }
}