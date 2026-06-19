var resp = context.getVariable("response.content");
var respJson = JSON.parse(resp);

// var reqtoken = parseInt(respJson.usage.input_tokens);
var reqtoken = respJson.usage.prompt_tokens;
var restoken = respJson.usage.completion_tokens;
var addcount = reqtoken + restoken;

var llm_response = respJson.choices[0].message.content;
var llm_model = respJson.model;

// don't extract the token usage from cached response
var cache_hit = context.getVariable("SemanticCacheLookup.SCL-aigw-text.cache_hit");
if( cache_hit == true ){
  context.setVariable("aigw.reqtoken", "0");
  context.setVariable("aigw.restoken", "0");
  context.setVariable("aigw.addcount", "0");
}else{
  context.setVariable("aigw.reqtoken", reqtoken);
  context.setVariable("aigw.restoken", restoken);
  context.setVariable("aigw.addcount", addcount.toString());  
}

context.setVariable("aigw.response", llm_response);
context.setVariable("aigw.response_model", llm_model);