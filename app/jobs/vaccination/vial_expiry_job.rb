# Vencimento dos frascos multidose (ADR 0047, Desvio 8): por cidade com a sala
# de vacina utilizável (lido fora de qualquer transação da cidade), todo frasco
# aberto com `expires_at` passado é fechado sem autor nem motivo, gravando a
# perda técnica = doses que sobraram. Cada frasco numa transação própria, com
# FOR UPDATE e releitura (descarte ou outra rodada pode ter fechado antes). Uma
# falha num frasco não para os demais: vai ao log só com o id e a classe do
# erro, e o job falha no fim com a contagem (o EachCityJob junta as cidades).
module Vaccination
  class VialExpiryJob < ApplicationJob
    prepend EachCityJob
    queue_as :housekeeping

    def perform
      return unless Gate.usable?(Current.city)

      now = Time.current
      failed = 0
      VialOpening.open_vials.where(expires_at: ..now).order(:expires_at, :id).pluck(:id).each do |id|
        expire!(id, now)
      rescue => e
        failed += 1
        Rails.logger.error("[#{self.class.name}] vial=#{id} failed: #{e.class}")
      end
      raise "#{failed} vial(s) failed" if failed.positive?
    end

    private

    def expire!(id, now)
      VialOpening.transaction(requires_new: true) do
        vial = VialOpening.lock("FOR UPDATE").find(id)
        next if vial.closed_at

        vial.update!(closed_at: now, technical_loss_doses: vial.doses_left)
        DomainEvents.publish("vaccination.vial_closed", vial_opening_id: vial.id, vaccine_room_id: vial.vaccine_room_id,
                                                        user_id: nil, cause: "expired")
      end
    end
  end
end
