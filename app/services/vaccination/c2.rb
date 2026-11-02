# Boa prática E do C2 (módulo 29, ADR 0047; contrato §10; nota metodológica
# do C2, item g e Quadro 05), pela interpretação de config/vaccination/c2_schedule.yml:
# penta, VIP, SCR e pneumocócica com todas as doses, contadas POR COMPONENTE
# (a hexa vale para a penta e para a VIP; a SCRV para a SCR), com intervalo
# mínimo entre doses do mesmo componente e idade mínima do grupo (SCR a partir
# de 365 dias de vida). Ruby puro: recebe as doses ATIVAS (transcrição inclusive).
module Vaccination
  module C2
    module_function

    # doses: [ { code:, on: Date } ]. Dia em que o último componente fechou, ou nil.
    def met_on(doses:, birth_date:)
      return nil unless birth_date

      by_component = Hash.new { |h, k| h[k] = [] }
      doses.each do |dose|
        Array(schedule["codes"][Immunobiologicals.normalize(dose[:code])]).each { |component| by_component[component] << dose[:on] }
      end
      gap = schedule.fetch("min_interval_days")
      closed = schedule.fetch("groups").flat_map do |group|
        from = birth_date + group["min_age_days"].to_i
        group.fetch("components").map { |component| nth_valid(by_component[component], from: from, gap: gap, need: group.fetch("doses")) }
      end
      closed.all? ? closed.max : nil
    end

    # Códigos que contam para o C2 (sem zero à esquerda).
    def codes = schedule.fetch("codes").keys

    def schedule = YamlFiles.load("c2_schedule")

    # Data da `need`-ésima dose válida: na idade mínima e a `gap` dias da anterior válida.
    def nth_valid(dates, from:, gap:, need:)
      taken = nil
      count = 0
      dates.sort.each do |on|
        next if on < from || (taken && (on - taken).to_i < gap)

        taken = on
        count += 1
        return on if count == need
      end
      nil
    end
    private_class_method :nth_valid
  end
end
