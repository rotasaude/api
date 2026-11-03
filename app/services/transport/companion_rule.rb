# Regra do acompanhante (ADR 0048; plano, Desvio 5; §14 T17), na data da
# viagem:
#  - fora do TFD: sem motivo só se a idade <= companion_rule.max_age_child ou
#    >= companion_rule.min_age_elderly (padrão 15 e 60, da cidade); fora disso
#    o motivo (já conferido 10..500 por quem chama) libera;
#  - no TFD (origin "tfd"): só com `report.companion_indicated` do laudo; nem
#    o motivo nem a idade suprem a indicação.
# Idade desconhecida (sem nascimento) conta como fora da faixa. Só devolve o
# símbolo: nada do paciente nem do laudo sai daqui.
module Transport
  module CompanionRule
    module_function

    # -> :ok | :companion_not_allowed
    def check(patient:, on:, origin:, tfd_case:, reason:)
      if origin == "tfd"
        report = tfd_case&.report
        return report.is_a?(Hash) && report["companion_indicated"] == true ? :ok : :companion_not_allowed
      end
      return :ok if reason.present?

      setting = Settings.current
      age = patient.age(on: on)
      return :companion_not_allowed if age.nil?

      age <= setting.companion_max_age_child || age >= setting.companion_min_age_elderly ? :ok : :companion_not_allowed
    end
  end
end
