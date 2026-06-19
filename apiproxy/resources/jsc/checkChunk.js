print(context.getVariable("response.event.current.data"));
print(context.getVariable("response.event.current.content"));
// print(context.getVariable("response.event.current.content"));

const chunk = context.getVariable("response.event.current.data");
const completion_tokens, prompt_tokens, total_tokens, modedlid_res
var modelid_billing;

if( !chunk.startsWith('[DONE]')){
  var data = JSON.parse(context.getVariable("response.event.current.data"));
  if( data.usage ){
    completionTokens = data && data.usage && data.usage.completion_tokens || 0;
    reasoningTokens = data && data.usage && data.usage.completion_tokens_details && data.usage.completion_tokens_details.reasoning_tokens || 0;
    promptTokens = data && data.usage && data.usage.prompt_tokens || 0;
    totalTokens = data && data.usage && data.usage.total_tokens || 0;
    cachedTokens = data && data.usage && data.usage.prompt_tokens_details && data.usage.prompt_tokens_details.cached_tokens || 0;
 

    if(totalTokens != 0){
      modelid_res = data.model;

      context.setVariable('completionTokens', completionTokens);
      context.setVariable('reasoningTokens', reasoningTokens);
      context.setVariable('promptTokens', promptTokens);
      context.setVariable('totalTokens', totalTokens);
      context.setVariable('aigw.modelid_res', data.model)
      context.setVariable('cachedTokens', cachedTokens);

      if( modelid_res.startsWith("google/") ){
        modelid_billing = modelid_res.substring(7);
      }else if( modelid_res.startsWith("gpt-4.1-mini") ){
        modelid_billing = "gpt-4.1-mini";
      }else if( modelid_res.startsWith("gpt-4o-mini") ){
        modelid_billing = "gpt-4o-mini";
      }else{
        modelid_billing = modelid_res;
      }

      context.setVariable('aigw.modelid_billing', modelid_billing);
      
    }
  }
}
