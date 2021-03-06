class Doze::Responder::Resource < Doze::Responder
  include Doze::Utils

  attr_reader :resource, :options

  def initialize(app, request, resource, options={})
    super(app, request)
    @resource = resource
    @options = options
  end


  # Basic handling of method support and OPTIONS

  def response
    if @request.options?
      Doze::Response.new(STATUS_NO_CONTENT, allow_header)
    elsif !@resource.supports_method?(recognized_method)
      error_response(STATUS_METHOD_NOT_ALLOWED, nil, allow_header)
    else
      response_to_supported_method
    end
  end

  def allow_header
    methods = @app.config[:recognized_methods].select {|m| @resource.supports_method?(m)}
    # We support OPTIONS for free, and HEAD for free if GET is supported
    methods << :head if methods.include?(:get)
    methods << :options
    {'Allow' => methods.map {|method| method.to_s.upcase}.join(', ')}
  end



  # Handling for supported methods

  def response_to_supported_method
    fail = authorization_fail_response(recognized_method) and return fail

    exists = @resource.exists?

    if @request.get_or_head?
      return error_response(STATUS_NOT_FOUND) unless exists
      response = resource_preconditions_fail_response || make_representation_of_resource_response
      response.head_only = @request.head?
      response
    else
      entity = @request.entity
      if entity && recognized_method != :delete
        fail = request_entity_media_type_fail_response(recognized_method, entity) and return fail
      end

      # Where the resource supports GET, we can use this to support preconditions (If-Match etc)
      # on PUT/DELETE/POST operations based on the content that GET would return.
      if exists && @resource.supports_get?
        fail = resource_preconditions_fail_response and return fail
        fail = entity_preconditions_fail_response and return fail
      end

      perform_non_get_action(entity, exists)
    end
  end

  def perform_non_get_action(entity, existed_before)
    case recognized_method
    when :post
      # Slightly hacky but for now we allow the session to be passed as an extra arg to post actions
      # where the method has sufficient arity.
      #
      # This is only supported for POST at present; prefered approach (especially for GET/PUT/DELETE)
      # is to use a session-specific route and construct the resource with the session context.
      # Also, this should not be used for authorization logic - use the authorize method for that.
      result = if @resource.method(:post).arity.abs > 1
        @resource.post(entity, @request.session)
      else
        @resource.post(entity)
      end

      # 201 created is the default interpretation of a new resource with an identifier resulting from a post.
      make_post_result_response(result)

    when :put
      if entity
        result = @resource.put(entity)
        Doze::Response.new_empty(existed_before ? STATUS_NO_CONTENT : STATUS_CREATED)
      else
        error_response(STATUS_BAD_REQUEST, "expected request body for PUT")
      end

    when :delete
      result = @resource.delete_resource if existed_before
      Doze::Response.new_empty

    else
      result = @resource.other_method(recognized_method, entity)
      # For now we streat this pretty much as a POST
      make_post_result_response(result)
    end
  end





  # Precondition checkers

  def request_entity_media_type_fail_response(resource_method, entity)
    unless @resource.accepts_method_with_media_type?(resource_method, entity)
      error_response(STATUS_UNSUPPORTED_MEDIA_TYPE)
    end
  end

  def authorization_fail_response(action)
    auth_failed_response unless @resource.authorize(@request.session, action)
  end

  def resource_preconditions_fail_response
    last_modified = @resource.last_modified or return
    if_modified_since   = @request.env['HTTP_IF_MODIFIED_SINCE']
    if_unmodified_since = @request.env['HTTP_IF_UNMODIFIED_SINCE']

    if (if_unmodified_since && last_modified > Time.httpdate(if_unmodified_since))
      # although technically an HTTP error response, we don't use error_response (and an error resource)
      # to send STATUS_PRECONDITION_FAILED, since the precondition check was something the client specifically
      # requested, so we assume they don't need a special error resource to make sense of it.
      Doze::Response.new(STATUS_PRECONDITION_FAILED, 'Last-Modified' => last_modified.httpdate)
    elsif (if_modified_since && last_modified <= Time.httpdate(if_modified_since))
      if request.get_or_head?
        Doze::Response.new(STATUS_NOT_MODIFIED, 'Last-Modified' => last_modified.httpdate)
      else
        Doze::Response.new(STATUS_PRECONDITION_FAILED, 'Last-Modified' => last_modified.httpdate)
      end
    end
  end

  # Etag-based precondition checks. These are specific to the response entity that would be returned
  # from a GET.
  #
  # Note: the default implementation of entity.etag just generates the entity body and hashes it,
  # but you could return entities which lazily know their Etag without the body needing to be generated,
  # and this code will take advantage of that
  def entity_preconditions_fail_response(entity=nil)
    if_match      = @request.env['HTTP_IF_MATCH']
    if_none_match = @request.env['HTTP_IF_NONE_MATCH']
    return unless if_match || if_none_match

    entity ||= get_preferred_representation
    return unless entity.is_a?(Doze::Entity)

    etag = entity.etag

    # etag membership test is kinda crude at present, really we should parse the separate quoted etags out.
    if (if_match      && if_match != '*' &&      !(etag && if_match.include?(quote(etag))))
      Doze::Response.new(STATUS_PRECONDITION_FAILED, 'Etag' => quote(etag))
    elsif (if_none_match && (if_none_match == '*' || (etag && if_none_match.include?(quote(etag)))))
      if @request.get_or_head?
        Doze::Response.new(STATUS_NOT_MODIFIED, 'Etag' => quote(etag))
      else
        Doze::Response.new(STATUS_PRECONDITION_FAILED, 'Etag' => quote(etag))
      end
    end
  end




  # Response handling helpers

  def get_preferred_representation(response=nil)
    representation = @resource.get
    if representation.is_a?(Array)
      negotiator = @request.negotiator(@options[:ignore_unacceptable_accepts])

      if response
        # If the available representation entities differ by media type, add a Vary: Accept. similarly for language.
        response.add_header_values('Vary', 'Accept') if not_all_equal?(representation.map {|e| e.media_type})
        response.add_header_values('Vary', 'Accept-Language') if not_all_equal?(representation.map {|e| e.language})
      end

      # If we fail to find the requested media type when requested via a file extension (/foo.jpeg) the appropriate HTTP status
      # is 404; at the HTTP level this is effectively a separate media-type-specific version of the resource at its own uri,
      # which doesn't exist due to the particular media-type-specific version of the resource not being available.
      # If we fail due to an Accept header not matching anything, of course the appropriate status is STATUS_NOT_ACCEPTABLE
      negotiator.choose_entity(representation) or raise_error(@request.extension ? STATUS_NOT_FOUND : STATUS_NOT_ACCEPTABLE)
    else
      representation
    end
  end

  def not_all_equal?(collection)
    first = collection.first
    collection.any? {|x| x != first}
  end

  def add_caching_headers(response)
    # resource-level caching metadata headers
    last_modified = @resource.last_modified and response.headers['Last-Modified'] = last_modified.httpdate
    case @resource.cacheable?
    when true
      expiry_period = @resource.cache_expiry_period
      if @resource.publicly_cacheable?
        cache_control = 'public'
        if expiry_period
          cache_control << ", max-age=#{expiry_period}"
          public_expiry_period = @resource.public_cache_expiry_period
          cache_control << ", s-maxage=#{public_expiry_period}" if public_expiry_period
        end
      else
        cache_control = 'private'
        cache_control << ", max-age=#{expiry_period}" if expiry_period
      end
      response.headers['Expires'] = (Time.now + expiry_period).httpdate if expiry_period
      response.headers['Cache-Control'] = cache_control
    when false
      response.headers['Expires'] = 'Thu, 01 Jan 1970 00:00:00 GMT' # Beginning of time woop woop
      response.headers['Cache-Control'] = 'no-cache, max-age=0'
    end
  end

  def make_representation_of_resource_response(include_location_with_status=nil)
    response = Doze::Response.new
    representation = get_preferred_representation(response)

    case representation
    when Doze::Resource
      raise 'Resource representation must have a uri' unless representation.uri
      response.set_redirect(representation, @request)
      add_caching_headers(response)
      response
    when Doze::Entity
      # preconditions on the representation only apply to the content that would be served up by a GET
      fail_response = @request.get_or_head? && entity_preconditions_fail_response(representation)
      response = fail_response || begin
        response.entity = representation
        response
      end
      add_caching_headers(response)

      if include_location_with_status && @resource.uri
        response.set_location(@resource, @request)
        response.status = include_location_with_status
      end

      response
    when Doze::Response
      representation
    end
  end

  def make_post_result_response(result)
    case result
    when Doze::Resource
      Doze::Responder::Resource.new(@app, @request, result, @options).make_representation_of_resource_response(STATUS_CREATED)
    when Doze::Entity
      Doze::Response.new_from_entity(result)
    when Doze::Response
      result
    when nil
      Doze::Response.new_empty
    end
  end
end
