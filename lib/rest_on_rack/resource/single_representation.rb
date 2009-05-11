module Rack::REST::Resource::SingleRepresentation
  def media_type; 'text/html'; end
  def language; end
  def data; ''; end

  def get_entity_representation
    Rack::REST::Entity.new(:media_type => media_type, :language => language) {data}
  end
end