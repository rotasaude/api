# Re-encripta colunas Active Record Encryption com a chave DERIVADA atual da
# cidade (Plano 7 muda o que "chave atual" significa — ver correção abaixo).
#
# Fluxo (R41): record.encrypt lê cada atributo encriptado do registro (decifra
# via chave primária ou prior_keys) e o regrava com update_columns, cifrado com
# a chave PRIMÁRIA atual — sem validações, callbacks nem updated_at.
# Reatribuir o mesmo valor (`record[attr] = record[attr]`) NÃO serve: não suja
# o atributo e o save! não emite UPDATE, então a rotação ficava sem efeito.
# Idempotente no conteúdo — re-rodar com a mesma chave regrava o mesmo texto
# claro (o ciphertext muda por causa do IV aleatório, salvo `deterministic`).
#
# Roda uma vez por cidade (EachCityJob), sobre as tabelas do banco da cidade.
# O access_token do canal (CityChannel) mora na PLATAFORMA e não entra aqui:
# rodado por cidade seria recifrado N vezes.
#
# Correção (fix F6, rodada final de revisão): este comentário atribuía a
# rotação de chave por cidade e de plataforma ao "Plano 4" — não é mais assim.
# Este job SÓ re-cifra sob a chave DERIVADA ATUAL da cidade (a mesma que
# CityConnection.with já instala); ele não conhece nem consulta chave
# anterior nenhuma — a premissa de `prior_keys`/lista de chaves do parágrafo
# original não é alcançável aqui: `CityEncryption.key_provider` (Plano 7)
# monta o provider de uma chave SÓ, derivada de
# `config.active_record.encryption.primary_key` (fixo) + `city.encryption_key`
# corrente — nunca de `config.previous` (ver deploy/SECRETS.md, "Rotação").
# Rotação ENTRE duas chaves — a plataforma trocar de material, ou uma cidade
# trocar do dela — é `CityRekey`, que lê num contexto e grava em outro dentro
# de uma única transação; este job não serve para isso.
# NÃO chamar enquanto outra operação está rotacionando — pode interleave com
# chaves diferentes (sem perda, mas reescreve duas vezes).
class ReencryptionJob < ApplicationJob
  prepend EachCityJob
  queue_as :housekeeping

  # Registry (Model, atributo) — única fonte é CityEncryption::CITY_KEYED_TARGETS
  # (fix F6); CityRekey::TARGETS aponta para o mesmo array.
  TARGETS = CityEncryption::CITY_KEYED_TARGETS

  BATCH_SIZE = 200

  # Para limitar a rotação: ReencryptionJob.perform_now(only: [:user])
  # Sem args, rotaciona todos os targets.
  def perform(only: nil)
    selected = only ? TARGETS.select { |m, _| only.map(&:to_sym).include?(m.name.underscore.to_sym) } : TARGETS

    stats = {}
    selected.each do |model, attr|
      stats[model.name] = reencrypt(model, attr)
    end
    Rails.logger.info("[ReencryptionJob] done #{stats.inspect}")
    stats
  end

  private

  def reencrypt(model, attr)
    count = 0
    model.unscoped.find_each(batch_size: BATCH_SIZE) do |record|
      next if record[attr].nil?
      record.encrypt
      count += 1
    end
    count
  rescue => e
    Rails.logger.error("[ReencryptionJob] #{model.name}##{attr} falhou em row #{count}: #{e.message}")
    raise
  end
end
