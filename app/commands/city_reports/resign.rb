# Reescreve as assinaturas de relatório de UMA cidade com a chave derivada dela
# (Plano 8). Roda dentro de CityConnection.with: Current.city governa a chave.
#
# ApplicationRecord.transaction, NÃO ActiveRecord::Base.transaction — dentro de
# connected_to_many esta última abre na conexão `primary`, que é o banco vazio
# rota_saude_no_city_selected (mesmo tropeço do Plano 7, Task 4).
#
# updated_at não muda: `update_columns` (abaixo) escreve só as colunas passadas
# a ele e nunca consulta record_timestamps — não seria `save`/`update`/`touch`
# que injetam timestamp, então não há nada para desligar aqui. Importa porque
# reassinar não é mudança de domínio, e sweep_abandoned_conversations_job e a
# query de overview selecionam por updated_at.
module CityReports
  module Resign
    def self.call
      count = 0

      ApplicationRecord.transaction do
        ReportSnapshot.live.find_each do |snapshot|
          signature = ReportSnapshot.sign(snapshot.token)
          next if ActiveSupport::SecurityUtils.secure_compare(snapshot.signature, signature)

          snapshot.update_columns(signature: signature)
          count += 1
        end
      end

      Result.ok(count: count)
    rescue CityEncryption::MissingKey => e
      Result.fail(:missing_key, message: e.message)
    end
  end
end
