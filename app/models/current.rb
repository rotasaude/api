# CurrentAttributes resetado por request e por job (ver ADR-0003).
class Current < ActiveSupport::CurrentAttributes
  attribute :session
  # Cidade resolvida pelo host. Serve para log e para o envelope de resposta.
  # NUNCA use em WHERE: o escopo é a conexão, não um valor de coluna.
  attribute :city
  # Sessão de operador JÁ verificada por TOTP, no console de plataforma (admin.*).
  # Nunca coexiste com uma cidade resolvida: o console não resolve cidade.
  attribute :operator_session
  # Sessão de mantenedor JÁ verificada por TOTP, na API de manutenção
  # (maintenance-api.*). Nunca coexiste com uma cidade resolvida ou com uma
  # sessão de operador: a API de manutenção não resolve cidade.
  attribute :maintainer_session
  # Credencial resolvida para a requisição corrente da API de manutenção:
  # sessão humana OU token de serviço, nunca os dois (Plano 3, Task 2).
  attribute :maintenance_credential
  # Flag curta (Plano 7, fix round 2 do CityRekey): quando :platform,
  # CityDeterministicKeyProvider serve o DeterministicKeyProvider GLOBAL em vez
  # do derivado por cidade. Existe porque dado pré-migração (antes deste plano)
  # foi cifrado com a chave determinística global, e `key_provider:` no
  # `encrypts` vence o contexto de cifra sempre — não há outro jeito de
  # alcançar essa leitura. Só CityRekey liga isto, e só ao redor do bloco de
  # LEITURA de uma migração `source: :platform`; nil (o padrão) preserva o
  # comportamento de sempre.
  attribute :deterministic_key_source

  delegate :user, to: :session, allow_nil: true
end
