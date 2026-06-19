import streamlit as st
import requests
import shutil
from google import genai
from google.genai import types
from google.genai import errors
from openai import AzureOpenAI, OpenAIError
import boto3
import json
import os
from dotenv import load_dotenv
import openai

load_dotenv()
from botocore.exceptions import ClientError

import logging

@st.cache_resource
def configure_logging():
    logging.basicConfig(level=logging.INFO)
    logging.info("Streamlit service started")

configure_logging()

# Load environment variables or set placeholders
APIGEE_HOSTNAME = os.environ.get('APIGEE_HOSTNAME', 'YOUR_APIGEE_HOSTNAME')
BASIC_CLIENT_ID = os.environ.get('BASIC_CLIENT_ID', 'YOUR_BASIC_CLIENT_ID')
BASIC_CLIENT_SECRET = os.environ.get('BASIC_CLIENT_SECRET', 'YOUR_BASIC_CLIENT_SECRET')
PREMIUM_CLIENT_ID = os.environ.get('PREMIUM_CLIENT_ID', 'YOUR_PREMIUM_CLIENT_ID')
PREMIUM_CLIENT_SECRET = os.environ.get('PREMIUM_CLIENT_SECRET', 'YOUR_PREMIUM_CLIENT_SECRET')

# import rag.research as research
st.set_page_config(page_title="🔍 Apigee AIGW for Multi-LLM", layout="wide")
st.markdown("""
<style>
.big-font {
    font-size:300px !important;
}
</style>
""", unsafe_allow_html=True)

st.title('🔍 Apigee AIGW Demo for Multi LLMs')

tab1, tab2, tab3  = st.tabs(["Get Token", "Demo - Seuciry, Quota, Routing LLMs", "Revoke Token" ])

Groups = {"Basic", "Premium"}
Users = {"Basic": ["Member1", "Member2"], "Premium":["PlatinumMember1", "PlatinumMember2"]}

Models = {
        "Google": ["gemini-2.5-flash", "gemini-3-flash-preview", "gemini-3.1-pro-preview", "gemini-3.1-flash-lite-preview"],
        "Azure": ["gpt-4.1-mini", "gpt-4o-mini"],
        "Anthropic": ["claude-sonnet-4-6"]
}

with tab1:

    def get_access_token(user_id, user_tier):

        if user_tier == 'Basic':
            client_id = BASIC_CLIENT_ID
            client_secret = BASIC_CLIENT_SECRET
        elif user_tier == 'Premium':
            client_id = PREMIUM_CLIENT_ID
            client_secret = PREMIUM_CLIENT_SECRET

        form_data = {
        "grant_type": "client_credentials",
        "client_id": client_id,
        "client_secret": client_secret,
        "app_enduser": user_id,
        }
        headers = {'Content-Type': 'application/x-www-form-urlencoded'}

        url = f"https://{APIGEE_HOSTNAME}/v1/apigee-aigw/oauth2/accesstoken"
        x = requests.post(url, data=form_data, headers=headers)
        response = x.json()

        st.session_state.accesstoken = response["access_token"]
        st.success(st.session_state.accesstoken)

    def selected():
        # do nothing
        if st.session_state.clicked == 2:
            st.session_state.clicked = 1
        else:
            st.session_state.clicked = 0
        print("select something")

    #enduser_id = st.text_input('Enduser ID', key='enduser_id' )
    col1, col2, col3 = st.columns([1,2,3])

    with col1:
        llm_group = st.selectbox("Select a Group", list(Users.keys()), key='llm_group_auth')
        #llm_apikey = Groups[llm_group]
        #print(llm_apikey)

    with col2:
        if llm_group:
            llm_user_options = Users[llm_group]
            llm_user = st.selectbox(f"Select a User from {llm_group}", llm_user_options, key='llm_user_auth')


    get_token = st.button('Get Token')

    if get_token :
        get_access_token(llm_user, llm_group)


with tab2:
    st.header("Demo - Security, Quota, Routing LLMs")

    if 'clicked' not in st.session_state:
        st.session_state.clicked = 0


    def stream_and_count_tokens(response_stream):

        total_tokens = 0
        completion_tokens = 0
        reasoning_tokens = 0
        prompt_tokens = 0
        content = ""

        for chunk in response_stream:
           
            if chunk.usage:
                total_tokens = chunk.usage.total_tokens or 0

                if total_tokens != 0:
                    st.session_state['total_tokens'] = total_tokens
                    st.session_state['completion_tokens'] = chunk.usage.completion_tokens
                    st.session_state['prompt_tokens'] = chunk.usage.prompt_tokens
                    st.session_state['modelid'] = chunk.model

                    if chunk.usage.completion_tokens_details:
                        st.session_state['reasoning_tokens'] = chunk.usage.completion_tokens_details.reasoning_tokens or 0
                    else:
                        st.session_state['reasoning_tokens'] = 0

                    if chunk.usage.prompt_tokens_details:
                        st.session_state['cached_tokens'] = chunk.usage.prompt_tokens_details.cached_tokens or 0
                    else:
                        st.session_state['cached_tokens'] = 0

            
            if chunk.choices and len(chunk.choices)>0:
                content = chunk.choices[0].delta.content or ""

            yield content

    #def call_aigw_count(input_text, llm_provider, llm_model, llm_apikey, llm_user):
    def call_aigw_token(input_text, llm_provider, llm_model):

        custom_headers = {
            #'apikey': "PuGi0gv2EyAa3IXbZ0IaGsJPDODQts1vJZl1XrWLYlo4nIBO",
            'Content-Type': 'application/json',
            #"x-apikey": f"{llm_apikey}",
            #"x-userid": f"{llm_user}",
            "x-accesstoken": f"{llm_access_token}"
        }

        # OpenAI Client
        client = openai.OpenAI(
            max_retries=0,
            ## base_url=f"https://{APIGEE_HOSTNAME}/v1/llm-gw",
            base_url=f"https://{APIGEE_HOSTNAME}/v1/apigee-aigw/route",
            default_headers=custom_headers,
            api_key="1234"
        )

        if llm_provider == "Google":
            modelid="google/" + llm_model
        else:
            modelid=llm_model


        try:
            #raw_response = client.chat.completions.with_raw_response.create(
            stream = client.chat.completions.create(
                messages=[
                    {
                        "role": "user",
                        "content": input_text
                    }
                ],
                model=modelid,
                stream=True,
                stream_options={"include_usage": True},
            )

            #st.write_stream(stream)
            st.write_stream(stream_and_count_tokens(stream))

            total_tokens = st.session_state['total_tokens']
            completions_tokens = st.session_state['completion_tokens']
            reasoning_tokens = st.session_state['reasoning_tokens']
            prompt_tokens = st.session_state['prompt_tokens']
            cached_tokens = st.session_state['cached_tokens']
            modelid_res = st.session_state['modelid']

            st.markdown(f'**model = {modelid_res}, prompt_tokens = {prompt_tokens}, completion_tokens = {completions_tokens}, reasoning_tokens = {reasoning_tokens}, total_tokens = {total_tokens}**' )



        except OpenAIError as e:
            print(str(e))
            st.markdown('     ')
            st.info(e.message)


    def selected():
        # do nothing
        if st.session_state.clicked == 0:
            st.session_state.clicked = 1
        else:
            st.session_state.clicked = 0
        print("select something")

    st.markdown("Basic Group Quota :  5 requests / 5 min,  2,000 tokens / 5 min ")
    st.markdown("Premium Group Quota : 20 requests / 5 min, 100,000 tokens / 5 min ")


    llm_access_token = st.text_input('Access Token', key='apigee_access_token_text', type='password')

    col1, col2, col3 = st.columns([1,2,3])

    with col1:
        llm_provider = st.selectbox("Select a Provider", list(Models.keys()), key='llm_provider_count')

    with col2:
        if llm_provider:
            llm_model_options = Models[llm_provider]
            llm_model = st.selectbox(f"Select a Model from {llm_provider}", llm_model_options, key='llm_model_count')

    llm_text = st.text_area('Enter text:', 'What is llm?', key='llm_text_count')
    llm_submitted = st.button('Submit', key='submit_text_count')

    if not llm_access_token:
        st.warning('Please enter your access token!', icon='⚠')
        # st.stop()

    if llm_access_token and llm_submitted:
        #call_aigw_count(llm_text, llm_provider, llm_model, llm_apikey, llm_user)
        call_aigw_token(llm_text, llm_provider, llm_model)


with tab3:
    st.header("Revoke Access Token")

    def revoke_token(token):
        form_data = {
                'token': token
        }
        headers = {'Content-Type': 'application/x-www-form-urlencoded'}

        url = f'https://{APIGEE_HOSTNAME}/v1/apigee-aigw/oauth2/invalidatetoken'
        x = requests.post(url, data=form_data, headers=headers)
        response = x.json()

        status = response["status"]
        st.write(token, status)

    def revoke_enduser(enduserid):
        form_data = {
                'enduser_id': enduserid
        }
        headers = {'Content-Type': 'application/x-www-form-urlencoded'}

        url = f'https://{APIGEE_HOSTNAME}/v1/apigee-aigw/oauth2/revoketoken'
        x = requests.post(url, data=form_data, headers=headers)
        response = x.json()

        status = response["status"]
        st.write(enduserid, status )

    token = st.text_input('Token')
    enduserid = st.text_input('EnduserID')
    revoke = st.button("Revoke Token", key='submit_revoke')

    if not token and not enduserid and revoke:
        st.warning('Please enter Token or EnduserID!')
        st.stop()
    elif token and revoke:
        revoke_token(token)
    elif enduserid and revoke:
        revoke_enduser(enduserid)
    else:
        st.stop()