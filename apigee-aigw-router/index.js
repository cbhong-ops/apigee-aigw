import express from 'express';
//import axios from 'axios';
import https from 'https';
import { GoogleAuth } from 'google-auth-library';
import { propertiesReader } from 'properties-reader';
import { Transform } from 'stream';
const properties = propertiesReader({ sourceFile: 'eval.properties' });

const app = express();
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

async function getGoogleAccessToken() {
    const auth = new GoogleAuth();
    const scopes = ['https://www.googleapis.com/auth/cloud-platform']; // Define required scopes

    const client = await auth.getClient({ scopes: scopes });
    const accessToken = await client.getAccessToken();
    console.log('Access Token:', accessToken.token);
    return accessToken.token;
}


app.post('/chat/completions', async (req, res) => {

    //const decode_inference_profile_arn = decodeURIComponent(inference_profile_arn);
    //console.log('first profile: ' + decode_inference_profile_arn);
    //decodeURIComponent(apikey)

    const model = req.body.model;
    const hostname = req.hostname;

    console.log('request model: ' + model)
    console.log('hostname: ' + hostname)

    const arr = hostname.split('.');
    const provider = properties.get(model + '.' + arr[0] + '.provider');
    const targetmodel = properties.get(model + '.' + arr[0] + '.model');
    const url = properties.get(model + '.' + arr[0] + '.url');
    const targethost = properties.get(model + '.' + arr[0] + '.hostname');
    const targeturl = 'https://' + targethost + url;
    const apikey = properties.get(model + '.' + arr[0] + '.apikey');
    var token;

    if (provider == 'google') {
        token = await getGoogleAccessToken();
    } else {
        token = apikey;
    }

    req.body.model = targetmodel;  // update model with target modelid
    var dataToSend = req.body;

    if (targetmodel.startsWith('claude')) {
        dataToSend = {
            anthropic_version: "vertex-2023-10-16",
            messages: req.body.messages,
            max_tokens: req.body.max_tokens || req.body.max_completion_tokens || 4096,
            stream: req.body.stream !== undefined ? req.body.stream : false
        };
        if (req.body.temperature !== undefined) dataToSend.temperature = req.body.temperature;
        if (req.body.top_p !== undefined) dataToSend.top_p = req.body.top_p;
    }

    const postData = JSON.stringify(dataToSend);
    console.log(JSON.stringify(postData, null, 2));

    console.log('targetmodel: ' + targetmodel);
    console.log('access token: ' + token);
    console.log('targeturl: ' + targeturl);
    console.log('req.body: ' + JSON.stringify(dataToSend));


    // http request options
    const options = {
        hostname: targethost,
        port: 443,
        path: url,
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ' + token
        }
    };

    // Send http request to Backend server
    const backendRequest = https.request(options, (backendResponse) => {
        let responseBody = '';

        if (backendResponse.statusCode !== 200) {
            console.error(`Backend Error - StatusCode: ${backendResponse.statusCode}`);

            // clientResponse.status(backendResponse.statusCode).json({
            res.status(502).json({
                error: 'Bad Gateway - Backend Error',
                message: backendResponse.statusMessage,
                backendStatus: backendResponse.statusCode
            });
            // console.error(`Return to Client - StatusCode: 502`);
            return;
        }


        // SSE Response Header
        res.writeHead(200, {
            'Content-Type': 'text/event-stream',
            'Cache-Control': 'no-cache',
            'Connection': 'keep-alive',
        });

        if (targetmodel.startsWith('claude')) {
            const claudeTransform = new Transform({
                transform(chunk, encoding, callback) {
                    if (!this.buffer) this.buffer = '';
                    this.buffer += chunk.toString();
                    const lines = this.buffer.split('\n');
                    this.buffer = lines.pop(); // Keep the last partial line

                    for (const line of lines) {
                        if (line.startsWith('data: ')) {
                            const dataStr = line.substring(6).trim();
                            if (dataStr === '[DONE]') {
                                const doneStr = 'data: [DONE]\n\n';
                                console.log('Converted Chunk: data: [DONE]');
                                this.push(doneStr);
                                continue;
                            }
                            try {
                                const data = JSON.parse(dataStr);
                                let openaiChunk = null;
                                if (data.type === 'message_start' && data.message && data.message.usage) {
                                    this.inputTokens = data.message.usage.input_tokens || 0;
                                } else if (data.type === 'content_block_delta' && data.delta && data.delta.text) {
                                    openaiChunk = {
                                        id: 'chatcmpl-' + Date.now(),
                                        object: 'chat.completion.chunk',
                                        created: Math.floor(Date.now() / 1000),
                                        model: model, // Use original model name
                                        choices: [{
                                            index: 0,
                                            delta: { content: data.delta.text },
                                            finish_reason: null
                                        }]
                                    };
                                } else if (data.type === 'message_delta' && data.delta && data.delta.stop_reason) {
                                    if (data.usage && data.usage.output_tokens !== undefined) {
                                        this.outputTokens = data.usage.output_tokens;
                                    }
                                    openaiChunk = {
                                        id: 'chatcmpl-' + Date.now(),
                                        object: 'chat.completion.chunk',
                                        created: Math.floor(Date.now() / 1000),
                                        model: model,
                                        choices: [{
                                            index: 0,
                                            delta: {},
                                            finish_reason: data.delta.stop_reason === 'end_turn' ? 'stop' : data.delta.stop_reason
                                        }]
                                    };

                                    // Add usage information to the final chunk if available
                                    if (this.inputTokens !== undefined || this.outputTokens !== undefined) {
                                        openaiChunk.usage = {
                                            prompt_tokens: this.inputTokens || 0,
                                            completion_tokens: this.outputTokens || 0,
                                            total_tokens: (this.inputTokens || 0) + (this.outputTokens || 0)
                                        };
                                    }
                                }

                                if (openaiChunk) {
                                    const resultStr = `data: ${JSON.stringify(openaiChunk)}\n\n`;
                                    console.log(`Converted Chunk: data: ${JSON.stringify(openaiChunk)}`);
                                    this.push(resultStr);
                                }
                            } catch (e) {
                                console.error('Failed to parse JSON:', dataStr);
                            }
                        }
                    }
                    callback();
                },
                flush(callback) {
                    if (this.buffer && this.buffer.startsWith('data: ')) {
                        const dataStr = this.buffer.substring(6).trim();
                        try {
                            const data = JSON.parse(dataStr);
                            if (data.type === 'content_block_delta' && data.delta && data.delta.text) {
                                const openaiChunk = {
                                    id: 'chatcmpl-' + Date.now(),
                                    object: 'chat.completion.chunk',
                                    created: Math.floor(Date.now() / 1000),
                                    model: model,
                                    choices: [{
                                        index: 0,
                                        delta: { content: data.delta.text },
                                        finish_reason: null
                                    }]
                                };
                                const resultStr = `data: ${JSON.stringify(openaiChunk)}\n\n`;
                                console.log(`Converted Chunk: data: ${JSON.stringify(openaiChunk)}`);
                                this.push(resultStr);
                            }
                        } catch (e) {
                            // Ignore parse error for partial lines at the end
                        }
                    }
                    const doneStr = 'data: [DONE]\n\n';
                    console.log('Converted Chunk: data: [DONE]');
                    this.push(doneStr);
                    callback();
                }
            });

            backendResponse.pipe(claudeTransform).pipe(res);
        } else {
            backendResponse.pipe(res);
        }


    });

    backendRequest.on('error', (error) => {
        console.error('Backend Connect Error :', error);
        // console.error(`Return to Client - StatusCode: 504`);
        if (!res.headersSent) {
            res.status(504).json({
                error: 'Gateway Error',
                message: 'Failed to connect to Backend'
            });
        }
    });

    backendRequest.write(postData);

    // finish the request to Backend
    backendRequest.end();

});


const port = parseInt(process.env.PORT) || 8080;
app.listen(port, () => {
    console.log(`apigee-aigw-router: listening on port ${port}`);
});
