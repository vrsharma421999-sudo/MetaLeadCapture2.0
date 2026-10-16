/**
 * @class        MetaConnectFacebookController
 * @description  Backs MetaConnectFacebook.page — the embedded "Continue with Facebook" login
 *               page hosted in an iframe on the Setup page's Integration Settings tab. Only
 *               ever renders non-secret values (App Id, Login Config Id, the caller's origin
 *               for postMessage) into the page; the actual OAuth code exchange happens
 *               server-side in MetaOAuthConnectService, never here.
 */
public without sharing class MetaConnectFacebookController {

    public String originParam { get; private set; }
    public String appId { get; private set; }
    public String configId { get; private set; }

    public MetaConnectFacebookController() {
        originParam = ApexPages.currentPage().getParameters().get('origin');
        Meta_Integration_Config__c setting = Meta_Integration_Config__c.getOrgDefaults();
        appId = setting.Meta_App_Id__c;
        configId = setting.Meta_App_Login_Config_Id__c;
    }
}