# Regra única de duplicidade (módulo 25, Desvio 4): bloqueia sugestão,
# "possível" e notificação nova do paciente para a doença quando há uma
# aberta (OPEN_STATUSES) ou uma fechada/digitada com closed_at há menos que
# repeat_after_days dias da cidade (fechada às 23h de ontem conta como
# ontem). `dismissed` não bloqueia. Quem grava trava antes (lock consultivo
# do CreateNotification); o índice único parcial decide o resto.
module Surveillance
  module Duplicates
    CLOSED_STATUSES = %w[closed entered].freeze

    module_function

    # today: o dia de referência no fuso da cidade. -> DiseaseNotification | nil
    # (a aberta, se houver; senão a fechada mais recente dentro da janela).
    def blocking(patient_id:, disease:, today:)
      scope = DiseaseNotification.where(patient_id: patient_id, disease_code: disease.code)
      scope.open_notifications.order(:created_at, :id).first ||
        scope.where(status: CLOSED_STATUSES, closed_at: window_start(disease, today)..).order(closed_at: :desc, id: :desc).first
    end

    # Primeiro instante (00:00 no fuso da cidade) do dia mais antigo que ainda
    # conta: com 30 dias, fechada há 29 dias bloqueia, há 30 libera.
    def window_start(disease, today) = (today - (disease.repeat_after_days - 1)).in_time_zone
    private_class_method :window_start
  end
end
