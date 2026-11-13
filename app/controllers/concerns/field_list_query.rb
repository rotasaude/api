# Parâmetros de query das listas da equipe do módulo 24b (ADR 0052; contrato
# §6, §7, §13): visita domiciliar e atividade coletiva. Quem inclui define
# `render_refusal(error, path: nil)` e `uuid?(value)`. Cada leitor devolve o
# valor ou nil; recusado, já respondeu 422 (performed?).
module FieldListQuery
  DEFAULT_LIMIT = 50
  MAX_LIMIT = 100
  DATE = /\A\d{4}-\d{2}-\d{2}\z/

  private

  # Tamanho da página: padrão 50, máximo 100; inválido → 422 invalid_limit (nil).
  def page_limit
    raw = params[:limit]
    return DEFAULT_LIMIT if raw.blank?

    value = Integer(raw.to_s, 10, exception: false)
    return value if value && value.between?(1, MAX_LIMIT)

    render_refusal("invalid_limit")
    nil
  end

  # Id opcional da query: ausente → nil; não-UUID → 422 invalid_request com
  # o path (performed?).
  def query_uuid(key)
    raw = request.query_parameters[key]
    return nil if raw.nil?
    return raw if uuid?(raw)

    render_refusal("invalid_request", path: key)
    nil
  end

  # Dia AAAA-MM-DD da query (o dia da cidade): ausente → nil; inválido → 422
  # invalid_request com o path (performed?).
  def query_date(key)
    raw = request.query_parameters[key]
    return nil if raw.nil?

    date = raw.is_a?(String) && raw.match?(DATE) && Date.strptime(raw, "%Y-%m-%d")
    return date if date

    render_refusal("invalid_request", path: key)
    nil
  rescue Date::Error
    render_refusal("invalid_request", path: key)
    nil
  end

  # Filtro repetido (`key[]=…`): ausente → nil; escalar, vazio ou valor fora
  # de `allowed` → 422 invalid_request com o path (performed?).
  def list_filter(key, allowed)
    return nil unless request.query_parameters.key?(key)

    values = request.query_parameters[key]
    return values.uniq if values.is_a?(Array) && values.any? && values.all? { |value| value.is_a?(String) && allowed.include?(value) }

    render_refusal("invalid_request", path: key)
    nil
  end
end
