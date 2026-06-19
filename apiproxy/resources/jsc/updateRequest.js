const jsonMaskingResponse = JSON.parse(context.getVariable("maskingResponse.content"));
const jsonReq = JSON.parse(context.getVariable("request.content"));
const result = jsonMaskingResponse.item.value;

jsonReq.messages[0].content = result;
context.setVariable("aigw.prompt", result);

var userid = context.getVariable("app_enduser");
context.setVariable("aigw.userid", userid);


//developer.app.name	app-multillm-basic
// if customer belong to Basic, change gemini-3-pro to gemini-3-flash
// const pathsuffix = context.getVariable("proxy.pathsuffix");
// const user_group = context.getVariable("developer.app.name");
// if( pathsuffix.startsWith("/base") && user_group == "app-multillm-basic"){
//   var modelid = jsonReq.model;

//   if( modelid.startsWith("google/gemini-3-pro")){
//     modelid = "google/gemini-3-flash-preview";
//     jsonReq.model = modelid;
//   }
// }

context.setVariable("request.content", JSON.stringify(jsonReq));