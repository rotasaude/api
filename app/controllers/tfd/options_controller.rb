# GET /tfd/options (§14 T7): o que a tela do laudo e a comissão escolhem —
# destinos ativos (<destination>), prestadores externos ativos do 26a (não
# `own`) com o município, e a distância mínima da cidade. Médico 225* ou
# comissão; sem dado de paciente, sem trilha.
module Tfd
  class OptionsController < BaseController
    def show
      return unless Access.committee?(Current.user) || require_physician!
      return unless query_only!

      destinations = TransportDestination.where(active: true).order(:name, :id)
      providers = CareProvider.active_providers.where.not(kind: "own").order(:name, :id)
      render json: { destinations: destinations.map { |d| Transport::Json.destination(d) },
                     providers: providers.map { |p| { id: p.id, name: p.name, ibge_code: p.ibge_code } },
                     min_distance_km: Transport::Settings.current.tfd_min_distance_km }
    end
  end
end
