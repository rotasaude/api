# Trava de transação que serializa o congelamento do público (DispatchJob) com o
# esquecimento por revogação (ForgetRevokedRecipients). Sob READ COMMITTED, uma
# revogação que comita entre o snapshot do INSERT…SELECT e o commit do dispatch
# deixaria a linha do cidadão revogado; com a trava, uma das duas espera a outra
# comitar e enxerga o resultado. Chamar dentro da transação da cidade; libera
# sozinha no commit/rollback.
module Campaigns
  module RecipientsFreezeLock
    KEY = "campaign_recipients_freeze".freeze

    def self.acquire!
      # execute, não select_value: pg_advisory_xact_lock devolve void.
      ApplicationRecord.connection.execute("SELECT pg_advisory_xact_lock(hashtext('#{KEY}'))")
    end
  end
end
