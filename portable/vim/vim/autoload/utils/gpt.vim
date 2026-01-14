vim9script

import autoload 'utils/curl.vim' as curl

g:default_openai_endpoint = 'https://api.openai.com/v1'
g:default_openai_api_key = getenv('OPENAI_API_KEY')

def BuildChatCompletionURL(): string
  const endpoint = get(g:, 'default_openai_endpoint', '')
  return endpoint .. '/chat/completions'
enddef

def BuildResponsesURL(): string
  const endpoint = get(g:, 'default_openai_endpoint', '')
  return endpoint .. '/responses'
enddef

def UseResponses(model: string, opts: dict<any>): bool
  if has_key(opts, 'use_responses')
    return opts['use_responses']
  endif
  if has_key(opts, 'use_chat') && opts['use_chat']
    return false
  endif
  if model =~? 'codex'
    return true
  endif
  return false
enddef

def UseChatCompletion(model: string, opts: dict<any>): bool
  if has_key(opts, 'use_chat')
    return opts['use_chat']
  endif
  return true
enddef

def ResolveResponseType(model: string, opts: dict<any>): string
  if UseResponses(model, opts)
    return 'responses'
  endif
  return 'chat'
enddef


def BuildHeaders(stream: bool = false): dict<string>
  var headers: dict<string> = {
    'Content-Type': 'application/json',
  }
  if stream
    headers['Accept'] = 'text/event-stream'
  endif

  var api_key = get(g:, 'default_openai_api_key', '')
  if api_key == ''
    throw 'OpenAI API key is not set. Please set the OPENAI_API_KEY environment variable or g:default_openai_api_key.'
  endif
  headers['Authorization'] = 'Bearer ' .. api_key
  return headers
enddef

def BuildMessages(prompt: string, system_prompt: string = ''): list<dict<string>>
  var messages: list<dict<string>> = []
  if system_prompt != ''
    add(messages, {'role': 'system', 'content': system_prompt})
  endif
  add(messages, {'role': 'user', 'content': prompt})
  return messages
enddef

def BuildChatPayload(
  messages: list<dict<string>>,
  model: string,
  stream: bool,
  extra_params: dict<any> = {}
): dict<any>
  var payload: dict<any> = {
    'model': model,
    'messages': messages,
    'stream': stream,
  }
  for [k, v] in items(extra_params)
    payload[k] = v
  endfor
  return payload
enddef

def BuildResponsesPayload(
  prompt: string,
  model: string,
  stream: bool,
  system_prompt: string,
  extra_params: dict<any> = {}
): dict<any>
  var payload: dict<any> = {
    'model': model,
    'input': prompt,
    'stream': stream,
  }
  if system_prompt != ''
    payload['instructions'] = system_prompt
  endif
  for [k, v] in items(extra_params)
    payload[k] = v
  endfor
  return payload
enddef


def CreateCall(
  model: string,
  prompt: string,
  use_responses: bool,
  use_chat: bool,
  opts: dict<any> = {}
): curl.Request
  const headers = BuildHeaders()
  const extra_params = get(opts, 'extra_params', {})
  var payload: dict<any>
  var endpoint: string
  if use_responses
    const system_prompt = get(opts, 'system_prompt', '')
    payload = BuildResponsesPayload(prompt, model, false, system_prompt, extra_params)
    endpoint = BuildResponsesURL()
  elseif use_chat
    const messages = BuildMessages(prompt, get(opts, 'system_prompt', ''))
    payload = BuildChatPayload(messages, model, false, extra_params)
    endpoint = BuildChatCompletionURL()
  else
    throw 'No valid response type selected.'
  endif

  const req = curl.Request.new(
    endpoint,
    {
      method: 'POST',
      headers: headers,
      data: json_encode(payload),
    }
  )
  return req
enddef

def ParseCallResponse(res: curl.Response, response_type: string): string
  if res.status != 200
    throw 'OpenAI API request failed with status ' .. string(res.status) .. ': ' .. json_encode(res.Body())
  endif
  const body = res.Body()
  if response_type ==# 'responses'
    echom json_encode(body)
    return body["output"][-1]["content"][-1]["text"]
  endif
  if response_type ==# 'chat'
    return body['choices'][0]['message']['content']
  endif
  return body['choices'][0]['text']
enddef

# Usage:
# ```
# Call(
#   'gpt-5',
#   'Hello, how are you?',
#   {
#     system_prompt: 'You are a friendly chatbot.',
#   }
# )
# ```
export def Call(
  model: string,
  prompt: string,
  opts: dict<any> = {}
): string
  const response_type = ResolveResponseType(model, opts)
  const use_responses = response_type ==# 'responses'
  const use_chat = response_type ==# 'chat'
  const req = CreateCall(model, prompt, use_responses, use_chat, opts)
  const res = req.Join()
  return ParseCallResponse(res, response_type)
enddef

export def CallAsync(
  model: string,
  prompt: string,
  cb: any,
  opts: dict<any> = {}
): void
  const response_type = ResolveResponseType(model, opts)
  const use_responses = response_type ==# 'responses'
  const use_chat = response_type ==# 'chat'
  const req = CreateCall(model, prompt, use_responses, use_chat, opts)
  const err_cb = get(opts, 'err_cb', v:none)
  req.Start()
  req.WaitAsync(100, (res) => {
    try
      const data = ParseCallResponse(res, response_type)
      call(cb, [data])
    catch
      const error_message = v:exception
      if type(err_cb) != v:t_none
        call(err_cb, [error_message])
      else
        echohl ErrorMsg
        echom error_message
        echohl None
      endif
    endtry
  })
enddef


def CreateCallTool(
  model: string,
  name: string,
  prompt: string,
  parameters: dict<any>,
  opts: dict<any> = {}
): curl.Request
  const use_chat = UseChatCompletion(model, opts)
  if !use_chat
    throw 'Tool calls require a chat-completions model. Set opts.use_chat to v:true or use a chat model.'
  endif
  const headers = BuildHeaders()
  const messages = BuildMessages(prompt, get(opts, 'system_prompt', ''))
  var base_extra = get(opts, 'extra_params', {})
  const tool_info = {
    'tools': [
      {
        'type': 'function',
        'function': {
          'name': name,
          'parameters': parameters,
        }
      }
    ],
    'tool_choice': {'type': 'function', 'function': {'name': name}},
  }
  const extra_params = extend(copy(base_extra), tool_info)
  const payload = BuildChatPayload(messages, model, false, extra_params)
  const endpoint = BuildChatCompletionURL()
  const req = curl.Request.new(
    endpoint,
    {
      method: 'POST',
      headers: headers,
      data: json_encode(payload),
    }
  )
  return req
enddef

def ParseCallToolResponse(res: curl.Response): dict<any>
  if res.status != 200
    throw 'OpenAI API request failed with status ' .. string(res.status) .. ': ' .. json_encode(res.Body())
  endif
  const body = res.Body()
  const data = body['choices'][0]['message']['tool_calls'][0]['function']['arguments']
  return json_decode(data)
enddef

# Usage:
# ```
# const res = CallTool(
#   'gpt-5',
#   'get_weather',
#   'What is the current weather in New York?',
#   {
#     'type': 'object',
#     'properties': {
#       'location': {'type': 'string', 'description': 'city name'},
#       'unit': {'type': 'string', 'enum': ['celsius', 'fahrenheit']},
#     },
#     'required': ['location'],
#   },
#   {
#     system_prompt: 'You can use get_weather tool to fetch current weather information.',
#   }
# )
# echo res["location"]
# ```
export def CallTool(
  model: string,
  name: string,
  prompt: string,
  parameters: dict<any>,
  opts: dict<any> = {}
): dict<any>
  const req = CreateCallTool(model, name, prompt, parameters, opts)
  const res = req.Join()
  return ParseCallToolResponse(res)
enddef

export def CallToolAsync(
  model: string,
  name: string,
  prompt: string,
  parameters: dict<any>,
  cb: any,
  opts: dict<any> = {}
): void
  const req = CreateCallTool(model, name, prompt, parameters, opts)
  const err_cb = get(opts, 'err_cb', v:none)
  req.Start()
  req.WaitAsync(100, (res) => {
    try
      const data = ParseCallToolResponse(res)
      call(cb, [data])
    catch
      const error_message = v:exception
      if type(err_cb) != v:t_none
        call(err_cb, [error_message])
      else
        echohl ErrorMsg
        echom error_message
        echohl None
      endif
    endtry
  })
enddef
