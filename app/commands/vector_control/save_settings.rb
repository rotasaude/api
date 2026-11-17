# Local de estoque de onde o boletim baixa (módulo 35a, ADR 0054; contrato §4):
# `stock_location_id` = um local `vector_control` ATIVO, ou nulo (sem baixa:
# cada aplicação vira falta no_location). Outro tipo, inativo ou inexistente →
# invalid_request path `stock_location_id`. A linha única nasce sob demanda
# (VectorControlSetting.current) e é travada FOR UPDATE; o local, FOR SHARE
# (a desativação dele trava a mesma linha). version + 1 quando muda.
module VectorControl
  module SaveSettings
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    module_function

    # -> Result.ok(setting:) | fail(:invalid_request, details: { path: "stock_location_id" })
    def call(stock_location_id:, by:)
      _ = by
      return invalid unless stock_location_id.nil? || (stock_location_id.is_a?(String) && stock_location_id.match?(UUID))

      VectorControlSetting.ensure_defaults!
      VectorControlSetting.transaction(requires_new: true) do
        setting = VectorControlSetting.lock.find(1)
        location = stock_location_id && StockLocation.active_locations.lock("FOR SHARE")
                                                     .find_by(id: stock_location_id.downcase, kind: "vector_control")
        next invalid if stock_location_id && location.nil?

        setting.stock_location_id = location&.id
        setting.update!(version: setting.version + 1) if setting.changed?
        Result.ok(setting: setting)
      end
    end

    def invalid = Result.fail(:invalid_request, details: { path: "stock_location_id" })
    private_class_method :invalid
  end
end
