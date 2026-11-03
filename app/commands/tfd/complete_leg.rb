# Trecho do TFD realizado (contrato §6; plano, Desvios 12–14; §14 T10, T11):
#   call       POST /tfd/legs/:id/done, pela comissão, só trecho de PASSAGEM
#              (frota → `fleet_leg_by_trip`: o de frota fica feito no
#              fechamento da viagem, pelo Tfd::FleetLegs);
#   complete!  o núcleo comum (passagem e frota), com o processo travado.
# Já feito → `tfd_leg_done`; processo fora de scheduled/travelling →
# `invalid_transition`. Marca `done_at`, grava o deslocamento
# (Allowances.for_leg!) e, na volta, a alimentação do par (Allowances.meals!);
# a primeira ida feita move scheduled → travelling. Publica tfd.leg_done
# (tfd_leg_id) e, se houve refeição, tfd.allowances_calculated (tfd_case_id,
# tfd_leg_id) — só ids.
#
# Ordem das travas (Ruling da Task 8): viagem → processo → trecho. O caminho
# da frota entra pelo Tfd::FleetLegs, que trava a viagem antes de chegar
# aqui; o Transport::CorrectAttendance trava a mesma viagem antes de conferir
# os trechos feitos — a correção e o fechamento nunca se cruzam. A passagem
# não tem viagem: trava só processo → trecho.
module Tfd
  module CompleteLeg
    OPEN = %w[scheduled travelling].freeze

    module_function

    # -> Result.ok(leg:, allowances:) | fail(:missing_role | :fleet_leg_by_trip | :tfd_leg_done | :invalid_transition)
    def call(leg:, by:, at: Time.current)
      return Result.fail(:missing_role) unless Access.committee?(by)
      return Result.fail(:fleet_leg_by_trip) if leg.mode == "fleet"

      settings = Transport::Settings.current
      complete!(leg, by: by, at: at, settings: settings)
    end

    # Núcleo (passagem e frota). `by` pode ser nil (evento sem autor).
    def complete!(leg, by:, at: Time.current, settings: Transport::Settings.current)
      TfdCase.transaction(requires_new: true) do
        tfd_case = TfdCase.lock.find(leg.tfd_case_id)
        leg.lock!
        next Result.fail(:tfd_leg_done) if leg.done?
        next Result.fail(:invalid_transition) unless OPEN.include?(tfd_case.status)

        leg.update!(done_at: at)
        leg.tfd_case = tfd_case
        cache = Billing::SigtapCache.new
        travel = Allowances.for_leg!(leg, settings: settings, cache: cache)
        meals = leg.direction == "return" ? Allowances.meals!(leg, settings: settings, cache: cache) : []
        if leg.direction == "outbound" && tfd_case.status == "scheduled"
          moved = Transition.call(tfd_case: tfd_case, to: "travelling", by: by)
          raise "tfd: scheduled → travelling refused" if moved.failure? # inalcançável: conferida sob a trava
        end

        DomainEvents.publish("tfd.leg_done", tfd_leg_id: leg.id)
        DomainEvents.publish("tfd.allowances_calculated", tfd_case_id: tfd_case.id, tfd_leg_id: leg.id) if meals.any?
        Result.ok(leg: leg, allowances: travel + meals)
      end
    end
  end
end
