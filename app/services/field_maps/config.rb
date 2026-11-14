# Leitura de config/field_maps.yml (módulo 24c, ADR 0053). Sem segredo.
module FieldMaps
  module Config
    module_function

    def pmtiles_bin = settings.fetch(:pmtiles_bin)
    def builds_index_url = settings.fetch(:builds_index_url)
    def build_url_template = settings.fetch(:build_url_template)
    def base_bbox = settings.fetch(:base_bbox).map(&:to_f)
    def cache_dir = Rails.root.join(settings.fetch(:cache_dir))

    def settings = Rails.application.config_for(:field_maps)
    private_class_method :settings
  end
end
