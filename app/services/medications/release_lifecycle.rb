# Ciclo de vida compartilhado das releases de importação (listas da Anvisa e
# catálogo CATMAT): `importing` parada há mais de uma hora vira `failed` (abre
# o índice único da importação em curso) e a falha é marcada sem mascarar o
# erro original.
module Medications
  module ReleaseLifecycle
    STALE_AFTER = 1.hour

    module_function

    def fail_stale!(release_class)
      release_class.where(status: "importing", imported_at: ...STALE_AFTER.ago).find_each { |old| old.update!(status: "failed") }
    end

    # Nunca mascara o erro original: se nem o `failed` grava, segue com o motivo.
    def mark_failed(release)
      release&.update!(status: "failed")
    rescue StandardError => e
      Rails.logger.error("[medications:release] não marcou failed: #{e.class}")
    end
  end
end
