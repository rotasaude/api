# E-mails da equipe de vigilância (módulo 25, ADR 0043). Só doença e unidade,
# contagens e nomes de unidade: nunca paciente, bairro, data de sintomas, id da
# notificação nem link com id — o texto manda abrir a fila no painel da cidade.
class SurveillanceMailer < ApplicationMailer
  def immediate(to:, disease_label:, unit_label:, possible:)
    @disease = disease_label
    @unit = unit_label
    @possible = possible
    mail(to: to, subject: "[rota-saúde] Nova notificação imediata: #{disease_label}, #{unit_label}")
  end

  def overdue(to:, count:, immediate_count:)
    @count = count
    @immediate_count = immediate_count
    mail(to: to, subject: "[rota-saúde] Notificações vencidas: #{count}")
  end

  def negatives(to:, week:, unit_labels:)
    @week = week
    @units = unit_labels
    mail(to: to, subject: "[rota-saúde] Negativa semanal pendente (semana #{week}): #{unit_labels.size} unidade(s)")
  end
end
