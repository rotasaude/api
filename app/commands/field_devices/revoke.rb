# Revoga um aparelho de campo (módulo 24b, ADR 0052; contrato §9.1, §9.2; Q7,
# Q21). Final: revogado → 409 device_already_revoked. A linha travada decide a
# corrida de duas revogações (dono e administrador, ou duas requisições do app).
# `reason`: user (o dono) | admin (municipal_admin) — com `by` gravado em
# revoked_by_user_id — | membership_ended | user_disabled (a borda do app,
# FieldAuthentication; sem autor: ck_field_devices_revoked_by). Quem chama já
# conferiu quem pode e o step-up. Evento só com ids e o motivo (código).
#
# -> ok(device:) | fail(:device_already_revoked)
module FieldDevices
  module Revoke
    module_function

    def call(device, by:, reason:)
      reason = reason.to_s
      raise ArgumentError, "motivo de revogação desconhecido" unless FieldSync::Catalog::REVOKED_REASONS.include?(reason)

      by_person = FieldSync::Catalog::REVOKED_BY_PERSON.include?(reason)
      raise ArgumentError, "revogação por pessoa exige by:" if by_person && by.nil?

      FieldDevice.transaction(requires_new: true) do
        device.lock!
        next Result.fail(:device_already_revoked) if device.revoked?

        device.update!(revoked_at: Time.current, revoked_reason: reason, revoked_by_user: by_person ? by : nil)
        DomainEvents.publish("field_device.revoked", field_device_id: device.id, user_id: device.user_id, reason: reason)
        Result.ok(device: device)
      end
    end
  end
end
