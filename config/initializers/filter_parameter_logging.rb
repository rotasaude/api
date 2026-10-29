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
  :subjective, :objective, :assessment, :plan, :text, :full_name, :social_name, :mother_name,
  # ADR 0031: a justificativa CID-10 do pedido de exame é um diagnóstico.
  :cid10_justification,
  # ADR 0032: PKCE, estado opaco do signer, valor da assinatura e o JSON
  # canônico (`code`, `state`, `token` e `cpf` já estavam na lista).
  :verifier, :prepared, :signature_value, :raw_signature, :canonical,
  # ADR 0033: conteúdo dos documentos clínicos, medicamentos e a conferência
  # pública (`:reason`, `:note`, `:cpf` e `/\Aq\z/` já estavam na lista).
  :content, :items, :free_text, :dosage_instructions, :dosage_summary, :printed_description, :cid10,
  :companion_name, :companion_kinship, :short_code, :birth_year,
  # O medicamento informado de fora vai pelo id do catálogo, na URL da consulta.
  /\Acatalog_item_id\z/,
  # ADR 0034: endereço, telefone e identificação do paciente/prescritor e o número SNCR.
  /\A(session_id|access_token|street|zip|address|phone|paper_number|sncr|patient_identification|prescriber_contact)\z/,
  # ADR 0035: a chamada dos "sistemas externos" do PEC traz CPF/CNS do
  # cidadão e do profissional e a assinatura na query (a linha "Started GET"
  # usa request.filtered_path, que aplica esta lista à query).
  /\A(documento-cidadao|documento-profissional|pec_sign)\z/,
  # ADR 0036: o arquivo em Base64, os valores do resultado, o solicitante
  # digitado (nome, CNS), o local da coleta e a referência externa da guia.
  /\A(data|values|critical|requester|requester_name|requester_cns|scheduled_place|external_reference)\z/,
  # ADR 0037: nome da mãe, informação clínica, quem retirou, quem foi avisado,
  # contatos da retificação, a restrição da amostra, o número do GAL, o código
  # de barras da amostra e o número da requisição (prefixo do código de barras):
  # pseudônimos do paciente. O TOTP da assinatura avançada (`totp`) já cai em `:otp`.
  /\A(mother_name|clinical_info|delivered_to|notified_person|contacts|restriction_note|gal_requisition|barcode|barcodes|number)\z/,
  # ADR 0038: o valor do controle, os códigos por nível e a justificativa da
  # exceção do CIQ (fala do paciente: urgência, quadro) e a coluna da ação
  # corretiva (texto livre; o bind do SQL usa o nome da coluna, não o `:text`
  # do parâmetro). (`:text`, `:note`, `:reason`, `values` e `barcode` já estão.)
  /\A(value|values|level_barcodes|justification|corrective_action)\z/,
  # ADR 0039 (D-U1): raça/cor, etnia e endereço do paciente para o BPA-I
  # (`zip`, `street` e `address` já estavam; aqui as chaves inteiras).
  /\A(race_color|ethnicity|address_zip|address_street|address_number|address_complement|address_district)\z/,
  # ADR 0040: condição declarada pelo cidadão, DUM e motivo da recusa da sugestão
  # (`:note` e `:reason` já cobrem a nota do contato e o motivo do encerramento).
  /\A(condition|anchor_date|dismiss_reason)\z/,
  # ADR 0042: cadastro territorial — só entram as chaves que ainda não eram
  # filtradas (`full_name`, `social_name`, `mother_name`, `address`, `phone`,
  # `cpf`, `cns`, `race_color`, `ethnicity` e `birth_date` já estão acima).
  :no_cpf_reason, :sociodemographic, :health_conditions, :street_situation,
  :living_conditions, :identification, :refused, :income_band, :living_since,
  :patient_demographics, :death_on,
  # ADR 0043: notificação compulsória — a ficha (agravo e campos do Sinan), o
  # número oficial, o motivo, a data de início dos sintomas, o código do agravo,
  # a marca de paciente novo e o IBGE de residência (`reason` já estava);
  # `disease` é o filtro da fila (GET /surveillance/notifications?disease=).
  # A classificação final do caso (confirmed/discarded/inconclusive) do
  # andamento (POST …/transition) é dado de saúde.
  /\A(form|official_number|reason|symptoms_on|disease_code|disease|new_patient|residence_ibge|classification)\z/,
  # ADR 0044: regulação municipal — a justificativa do pedido, o CID-10 e o
  # CIAP-2 da indicação, o número da autorização do sistema do estado, as
  # observações do agendamento e o local do atendimento (`reason` cobre
  # color_reason e skip_reason; `note` cobre notes). O alvo (`target_code`), a
  # cor sugerida/decidida e o resultado do acompanhamento dizem o que o
  # paciente procura e quão grave é: filtrados. O `filtered_path` só mascara o
  # valor na linha "Started GET"; a fila (query) segue funcionando.
  :justification, /\Acid10\z/, /\Aciap2\z/, :external_number, :schedule_notes, :place,
  /\A(target_code|suggested_color|color|result)\z/,
  # ADR 0045: farmácia — o prescritor e o número da notificação da receita
  # externa, a retenção do controlado/antimicrobiano e as quantidades contadas
  # e recebidas, e o fornecedor da entrada (numa doação de pessoa física é o
  # nome dela; `document.supplier`) (`reason`, `short_code`, `items` — que já
  # leva `lot_number` e `manufacturer` —, `new_patient`, `cpf`, `cns` e
  # `dosage_instructions` já estavam acima).
  /\A(prescriber|retention|notification_number|counted_quantity|quantity_received|supplier)\z/
]

# O gov.br volta pra cidade com ?grant=... na URL de redirect (Plano 3B); sem
# isso o grant assinado (uso único, 60 s, mas ainda um bearer de sessão) cai
# em claro no log de toda linha "Redirected to".
Rails.application.config.filter_redirect += [ /grant=/ ]

# ADR 0032: o retorno do PSC traz code e state na URL do dashboard.
Rails.application.config.filter_redirect += [ /code=/ ]
