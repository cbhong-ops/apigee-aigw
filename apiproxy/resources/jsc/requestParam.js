var userid = context.getVariable("app_enduser")
//var userid = context.getVariable("request.header.x-userid");
var modelid = context.getVariable("aigw.modelid");

// var req = context.getVariable("request.content");
// var reqJson = JSON.parse(req);
// var prompt = reqJson.messages[0].content;
// var modelid = reqJson.model;

// context.setVariable("aigw.prompt", prompt);
// context.setVariable("aigw.request_model_group", modelid);
// context.setVariable("aigw.modelid", modelid);


// get env
var envname= context.getVariable("environment.name");


// get params based on modelid, turn
// env - eval, qa, prod
var provider = context.getVariable("propertyset." + envname + "." + modelid +".primary.provider");
var auth = context.getVariable("propertyset." + envname + "." + modelid +".primary.auth");
var hostname = context.getVariable("propertyset." + envname + "." + modelid +".primary.hostname");
var url = context.getVariable("propertyset." + envname + "." + modelid +".primary.url");
var api_key = context.getVariable("propertyset." + envname + "." + modelid +".primary.api_key") || null;

context.setVariable("aigw.provider", provider);
context.setVariable("aigw.auth", auth);
context.setVariable("aigw.hostname", hostname);
context.setVariable("aigw.url", url);
context.setVariable("aigw.userid", userid);

if (api_key !== null && api_key !== undefined) {
      context.setVariable("request.header.Authorization", "Bearer " + api_key);
}

context.setVariable("aigw.targeturl", "https://" + hostname + url);

