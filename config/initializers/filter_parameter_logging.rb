# Parâmetros que NUNCA podem cair no log. Ver ADR-0007 e ADR-0013.
Rails.application.config.filter_parameters += [
  :passw, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn,
  :raw, :payload, :evidence, :phone, :body, :authorization,
  :grant, /\A(code|state)\z/
]

# O gov.br volta pra cidade com ?grant=... na URL de redirect (Plano 3B); sem
# isso o grant assinado (uso único, 60 s, mas ainda um bearer de sessão) cai
# em claro no log de toda linha "Redirected to".
Rails.application.config.filter_redirect += [ /grant=/ ]
