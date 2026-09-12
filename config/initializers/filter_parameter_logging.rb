# Parâmetros que NUNCA podem cair no log. Ver ADR-0007 e ADR-0013.
Rails.application.config.filter_parameters += [
  :passw, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn,
  :raw, :payload, :evidence, :phone, :body, :authorization
]
