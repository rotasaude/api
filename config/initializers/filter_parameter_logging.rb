# Parâmetros que NUNCA podem cair no log. Ver ADR-0007 e ADR-0013.
Rails.application.config.filter_parameters += [
  :passw, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn,
  :raw, :payload, :evidence, :phone, :body, :authorization,
  :grant, :cpf, :cns, :answer, :reason, :referral_note, :note, /\A(code|state)\z/,
  # M6 (fix round 2): o corpo do POST /graphql da API de manutenção. `code` já
  # era filtrado como parâmetro, mas o TOTP do step-up viaja DENTRO de
  # `variables` — que chega como string JSON de vários clientes — e a string
  # inteira caía em claro no "Parameters:" do log. `query` vai junto porque o
  # mesmo código pode vir escrito na própria operação, como literal.
  #
  # O log de GraphQL continua útil: `operationName` não é filtrado, e é ele que
  # diz qual operação a requisição executou.
  :variables, :query,
  # ADR 0027: perfil do par — dado de saúde sensível, nunca em log.
  :birth_date, :sex, :gender_identity,
  # ADR 0030: escuta inicial — sinais vitais e queixa são dado de saúde
  # (`:note` e `:reason` já cobrem complaint_note, orientation_note e
  # color_change_reason).
  :vitals, :ciap2,
  # ADR 0030: o termo da busca de CIAP-2 (POST /attendance/ciap2/search, `q`) é
  # a queixa sendo digitada. Ancorado: só a chave `q`, não toda chave com "q".
  /\Aq\z/,
  # ADR 0031: texto clínico da consulta e do adendo, e os nomes da pessoa.
  # (`:reason` e `:note` já cobrem o motivo do adendo e a nota da abertura.)
  :subjective, :objective, :assessment, :plan, :text, :full_name, :social_name, :mother_name
]

# O gov.br volta pra cidade com ?grant=... na URL de redirect (Plano 3B); sem
# isso o grant assinado (uso único, 60 s, mas ainda um bearer de sessão) cai
# em claro no log de toda linha "Redirected to".
Rails.application.config.filter_redirect += [ /grant=/ ]
