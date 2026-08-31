"""
诊断脚本：故意发一个超长请求给 Azure 端点，把真实返回的 status_code + 错误 body 存到文件里。
不使用任何真实用户数据，只用合成的重复文本撑大 payload。
不修改 notebook，不触碰 checkpoint/production 数据。
"""
import os
import json
import requests

endpoint_base = "https://aipolling.services.ai.azure.com/models"
api_version = "2024-05-01-preview"
url = f"{endpoint_base}/chat/completions?api-version={api_version}"

api_key = os.getenv("AZURE_API_KEY")
if not api_key:
    raise ValueError("AZURE_API_KEY environment variable is not set")

# 第一次用 4字符/token 估算的 7000 次重复（56万字符）实际只有 105,081 token，成功了
# 用实测比例 5.33 字符/token 校准，这次用 12000 次重复（约96万字符 ~= 18万 token）确保超限
filler = "This is a test sentence used only to inflate the prompt length for diagnostics. " * 12000
print(f"filler length (chars): {len(filler)}")

messages = [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": filler},
]

body = {
    "model": "gpt-oss-120b",
    "max_tokens": 100,
    "temperature": 0,
    "messages": messages,
}

headers = {
    "Content-Type": "application/json",
    "api-key": api_key,
}

response = requests.post(url, headers=headers, data=json.dumps(body))

out_path = "context_length_error_response.txt"
with open(out_path, "w", encoding="utf-8") as f:
    f.write(f"status_code: {response.status_code}\n")
    f.write(f"headers: {dict(response.headers)}\n\n")
    f.write("body:\n")
    f.write(response.text)

print(f"status_code: {response.status_code}")
print(f"saved full response to: {out_path}")
