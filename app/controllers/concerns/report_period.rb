# Período de lista/relatório (ADR 0031): `from`/`to` "AAAA-MM-DD" opcionais, no
# fuso da cidade (Time.zone dentro do request). Inválido → :invalid (a rota
# responde 422 invalid_period).
module ReportPeriod
  extend ActiveSupport::Concern

  DATE = /\A\d{4}-\d{2}-\d{2}\z/

  private

  def period
    [ [ :from, :beginning_of_day ], [ :to, :end_of_day ] ].map do |key, edge|
      value = params[key]
      next nil if value.blank?
      next :invalid unless value.is_a?(String) && value.match?(DATE)

      Date.iso8601(value).in_time_zone.public_send(edge)
    rescue Date::Error
      :invalid
    end
  end

  def invalid_period?(from, to) = from == :invalid || to == :invalid

  def render_invalid_period = render(json: { error: "invalid_period" }, status: :unprocessable_entity)
end
