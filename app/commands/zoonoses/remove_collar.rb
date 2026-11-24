# Retirada da coleira (módulo 35b, ADR 0054; contrato §6, Q20). Só da equipe
# (team?, senão missing_role); `reason` do catálogo sem `replaced`
# (MANUAL_REASONS: lost, death, other; `replaced` só vem da PlaceCollar; senão
# path reason) e `removed_on` (padrão hoje; depois de hoje →
# date_out_of_range; antes da colocação → path removed_on).
#
# A coleira não tem versão: "sai uma vez" (trigger) decide. Coleira já
# retirada, ou trocada entretanto → 409 collar_changed. Ordem de trava: o
# animal da coleira FOR UPDATE → a coleira FOR UPDATE (a da AnimalDeath e da
# PlaceCollar). `collar.removed` só com o id.
module Zoonoses
  module RemoveCollar
    EVENT = "collar.removed".freeze
    MANUAL_REASONS = (Catalog::REMOVAL_REASONS - %w[replaced]).freeze

    module_function

    # -> Result.ok(collar:) | fail(:invalid_request | :date_out_of_range, details: { path: })
    #    | fail(:missing_role | :collar_changed)
    def call(collar:, reason:, removed_on:, by:, today: Time.zone.today)
      return Result.fail(:missing_role) unless Access.team?(by)
      # `replaced` só nasce da PlaceCollar (a coleira nova); a retirada manual não o aceita.
      return invalid("reason") unless MANUAL_REASONS.include?(reason)

      on = removed_on.nil? ? today : (removed_on.is_a?(Date) ? removed_on : parse_date(removed_on))
      return invalid("removed_on") unless on
      return Result.fail(:date_out_of_range, details: { path: "removed_on" }) if on > today

      Collar.transaction(requires_new: true) do
        Animal.lock.find_by(id: collar.animal_id)
        locked = Collar.lock.find_by(id: collar.id)
        next Result.fail(:collar_changed) if locked.nil? || locked.removed?
        next invalid("removed_on") if on < locked.placed_on

        locked.update!(removed_on: on, removal_reason: reason)
        DomainEvents.publish(EVENT, collar_id: locked.id)
        Result.ok(collar: locked)
      end
    end

    def parse_date(value)
      return nil unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)

      Date.strptime(value, "%Y-%m-%d")
    rescue Date::Error
      nil
    end

    def invalid(path) = Result.fail(:invalid_request, details: { path: path })

    private_class_method :parse_date, :invalid
  end
end
