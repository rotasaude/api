# Triagem que caiu num pedido aberto do mesmo tipo (ADR 0029 §5.2): só acréscimo.
class AppointmentRequestTriage < ApplicationRecord
  belongs_to :request, class_name: "AppointmentRequest", inverse_of: :request_triages
  belongs_to :triage
end
