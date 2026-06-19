var reqtoken_raw = JSON.parse(context.getVariable("aigw.reqtoken_raw"));
var restoken_raw = JSON.parse(context.getVariable("aigw.restoken_raw"));
var addcount_raw = JSON.parse(context.getVariable("aigw.addcount_raw"));
var parts_raw = JSON.parse(context.getVariable("aigw.candidate_parts"));

var model_id = context.getVariable("aigw.model_raw");

const brackets_regex = /\[|\]/g;
const doulbequotes_regex = /"/g;

// don't extract the token usage from cached response
var cache_hit = context.getVariable("SemanticCacheLookup.SCL-aigw-text.cache_hit");
if( cache_hit == false ){
  context.setVariable('aigw.reqtoken', reqtoken_raw.join(''));
  context.setVariable('aigw.restoken', restoken_raw.join(''));
  context.setVariable('aigw.addcount', addcount_raw.join(''));
}else{
  context.setVariable("aigw.reqtoken", "0");
  context.setVariable("aigw.restoken", "0");
  context.setVariable("aigw.addcount", "0");
}

context.setVariable("aigw.response_model", model_id);
context.setVariable('aigw.response', parts_raw.join(' '));