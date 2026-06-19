var res = context.getVariable("response.content");
var resJson = JSON.parse(res);
var content = resJson.output.message.content[0].text;
var reqtoken = resJson.usage.inputTokens;
var restoken = resJson.usage.outputTokens;
var totaltoken = resJson.usage.totalTokens;

context.setVariable("aigw.content", content);
context.setVariable("aigw.reqtoken", reqtoken);
context.setVariable("aigw.restoken", restoken);
context.setVariable("aigw.totaltoken", totaltoken);