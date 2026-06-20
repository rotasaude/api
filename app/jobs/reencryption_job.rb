# Re-encripta colunas Active Record Encryption com a chave primária atual.
# Ver SECRETS.md (ADR-0024) — rotina pós-rotação de chave.
#
# Fluxo: ler o atributo (decifra via chave primária ou prior_keys) +
# reatribuir (marca dirty) + save!(validate: false) (re-cifra com primária).
# Operação idempotente — re-rodar com a mesma chave é no-op funcional.
#
# Cross-tenant (lê todas as cidades) — roda sob rota_admin (BYPASSRLS, ADR-0019).
# NÃO chamar enquanto outra operação está rotacionando — pode interleave com
# chaves diferentes (sem perda, mas reescreve duas vezes).
class ReencryptionJob < ApplicationJob
  prepend AdminRoleJob
  queue_as :housekeeping

  # Registry (Model, atributo) — manter espelhado com `encrypts` nos models.
  TARGETS = [
    [User,               :otp_secret],
    [Conversation,       :phone],
    [InboundMessage,     :raw],
    [Consent,            :evidence],
    [Author,             :token],
    [MunicipalityChannel, :access_token]
  ].freeze

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
      record[attr] = record[attr]
      record.save!(validate: false)
      count += 1
    end
    count
  rescue => e
    Rails.logger.error("[ReencryptionJob] #{model.name}##{attr} falhou em row #{count}: #{e.message}")
    raise
  end
end
