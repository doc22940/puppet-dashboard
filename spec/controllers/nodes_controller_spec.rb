require 'spec_helper'

describe NodesController, :type => :controller do
  include ReportSupport
  render_views

  describe "#index" do
    before :each do
      @node = create(:changed_node)
      @resource = @node.last_apply_report.resource_statuses.first
    end

    context "as HTML" do
      before { get :index }
      specify { response.should be_successful }
    end

    context "as JSON" do
      before { get :index, params: { format: 'json' } }
      specify { response.should be_successful }
      it "should return JSON" do
        struct = json_from_response_body
        struct.size.should == 1
        struct.first["name"].should == @node.name
      end
    end

    context "as YAML" do
      context "when using node classification" do
        before :each do
          SETTINGS.stubs(:use_external_node_classification).returns(true)
        end

        it "should return YAML when the nodes are valid" do
          get :index, params: { format: 'yaml' }

          response.should be_successful
          struct = yaml_from_response_body
          struct.size.should == 1
          struct.first["name"].should == @node.name
        end

        it "should propagate errors encountered when a node is invalid" do
          Node.any_instance.stubs(:compiled_parameters).raises ParameterConflictError
          expect { get :index, params: { format: 'yaml' }}.to raise_error(ParameterConflictError)
        end
      end

      context "when not using node classification" do
        it "should raise an error and respond 403" do
          SETTINGS.stubs(:use_external_node_classification).returns(false)
          get :index, params: { format: 'yaml' }

          response.body.should =~ /Node classification has been disabled/
          response.should_not be_successful
          response.should be_forbidden
        end
      end
    end

    context "as CSV" do
      let :header do
        CSV.generate_line %w[name            status            resource_count pending_count
                             failed_count    compliant_count   resource_type  title
                             evaluation_time file              line           time
                             change_count    out_of_sync_count skipped        failed ], :row_sep => ''
      end

      it "should make correct CSV" do
        get :index, params: { format: 'csv' }

        response.should be_successful
        response.body.split("\n").should =~ [
          header,
          "#{@node.name},changed,1,0,0,1,#{@resource.resource_type},#{@resource.title},#{@resource.evaluation_time},#{@resource.file},#{@resource.line},#{@resource.time},#{@resource.change_count},#{@resource.out_of_sync_count},#{@resource.skipped},#{@resource.failed}"
        ]

      end

      it "should handle unreported nodes" do
        unreported_node = create(:node)

        get :index, params: { format: 'csv' }

        response.should be_successful
        response.body.split("\n").should =~ [
          header,
          "#{@node.name},changed,1,0,0,1,#{@resource.resource_type},#{@resource.title},#{@resource.evaluation_time},#{@resource.file},#{@resource.line},#{@resource.time},#{@resource.change_count},#{@resource.out_of_sync_count},#{@resource.skipped},#{@resource.failed}",
          "#{unreported_node.name},,,,,,,,,,,,,,,"
        ]
      end

      %w[foo,_-' bar/\\$^ <ba"z>>].each do |name|
        it "should handle a node named #{name}" do
          node = create(:node, :name => name, :reported_at => @node.reported_at - 1)  # cannot be nil since PGS and MySQL sort nils differently
          get :index, params: { format: 'csv' }

          response.should be_successful

          CSV.parse(response.body).last.first.should == name
        end
      end

      it "should include the node's resources" do
        report = create(:report, :host => @node.name, :status => "failed", :time => Time.now)
        res1 = create(:resource_status, :report => report,
                      :resource_type     => "File",    :title        => "/etc/sudoers",
                      :evaluation_time   => 1.second,  :file         => "/etc/puppet/manifests/site.pp",
                      :line              => 1,         :tags         => ["file", "default"],
                      :time              => Time.now,  :change_count => 1,
                      :out_of_sync_count => 1,         :skipped      => false,
                      :failed            => false )

        res2 = create(:resource_status, :report => report,
                      :resource_type     => "File",    :title        => "/etc/hosts",
                      :evaluation_time   => 2.seconds, :file         => "/etc/puppet/manifests/site.pp",
                      :line              => 5,         :tags         => ["file", "default"],
                      :time              => Time.now,  :change_count => 2,
                      :out_of_sync_count => 2,         :skipped      => false,
                      :failed            => true )

        res1.reload
        res2.reload

        get :index, params: { format: 'csv' }

        response.should be_successful
        response.body.split("\n").should =~ [
          header,
          %Q[#{@node.name},failed,2,0,1,1,File,/etc/sudoers,1.0,/etc/puppet/manifests/site.pp,1,#{res1.time},1,1,false,false],
          %Q[#{@node.name},failed,2,0,1,1,File,/etc/hosts,2.0,/etc/puppet/manifests/site.pp,5,#{res2.time},2,2,false,true]
        ]
      end
    end
  end

  describe "#new" do
    it "should successfully render the new page" do
      get :new

      response.should be_successful
      assigns[:class_data].should include({:class=>"#node_class_ids", :data_source=>"/node_classes.json", :objects=>[]})
      assigns[:group_data].should include({:class=>"#node_group_ids", :data_source=>"/node_groups.json", :objects=>[]})
    end
  end

  describe "#create" do
    it "should create a node on successful creation" do
      post :create, params: { node: { name: 'foo' } }
      assigns[:node].name.should == 'foo'
    end

    it "should render error when creation fails" do
      post :create, params: { node: {} }
      response.should render_template('shared/_error')
      response.should be_successful

      assigns[:node].errors.full_messages.should == ["Name can't be blank"]
      assigns[:class_data].should include({:class=>"#node_class_ids", :data_source=>"/node_classes.json", :objects=>[]})
      assigns[:group_data].should include({:class=>"#node_group_ids", :data_source=>"/node_groups.json", :objects=>[]})
    end
  end

  describe "#show" do

    before :each do
      @node = create(:node)
    end

    context "as HTML" do
      it "should return HTML for an existing node" do
        get :show, params: { id: @node.name }

        response.should be_successful
        assigns[:node].name.should == @node.name
      end

      it "should return 404 Record Not found an unknown node" do
        # NOTE: Uncaught RecordNotFound exceptions cause Rails to render a 404
        # Not Found response in production. We may want to add our own
        # friendlier error handling, rather than letting Rails handle these.
        expect { get :show, params: { id: 'not_a_valid_node' } }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context "as JSON" do
      it "should return JSON for an existing node" do
        get :show, params: { id: @node.name, format: 'json' }

        response.should be_successful

        struct = json_from_response_body
        struct["name"].should == @node.name
      end

      it "should return an error for an unknown node" do
        # NOTE: In the future, it may be better to return a JSON object that
        # better describes the error. Currently we're raising RecordNotFound,
        # which returns an HTML page.
        expect { get :show, params: { id: 'not_a_valid_node', format: 'json' } }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context "as YAML" do
      context "when using node classification" do
        before :each do
          SETTINGS.stubs(:use_external_node_classification).returns(true)
        end

        it "should return YAML when the node is valid" do
          get :show, params: { id: @node.name, format: 'yaml' }

          response.should be_successful
          struct = yaml_from_response_body
          struct["name"].should == @node.name
        end

        it "should explain errors encountered when the node is invalid" do
          Node.any_instance.stubs(:compiled_parameters).raises ParameterConflictError
          get :show, params: { id: @node.name, format: 'yaml' }

          response.should_not be_successful
          response.body.should =~ /has conflicting variable\(s\)/
        end

        it "should return YAML for an empty node when the node is not found" do
          get :show, params: { id: 'nonexistent', format: 'yaml' }

          response.should be_successful
          struct = yaml_from_response_body
          struct.should include({'classes' => []})
        end
      end

      context "when not using node classification" do
        it "should raise an error and respond 403" do
          SETTINGS.stubs(:use_external_node_classification).returns(false)
          get :show, params: { id: @node.name, format: 'yaml' }

          response.body.should =~ /Node classification has been disabled/
          response.should_not be_successful
          response.should be_forbidden
        end
      end
    end
  end

  describe '#edit' do
    def do_get
      get :edit, params: { id: @node.id }
    end

    before :each do
      @node = create(:node)
    end

    it 'should render the edit template' do
      do_get
      assigns[:node].should == @node

      response.should render_template('edit')
      response.should be_successful

      assigns[:class_data].should include({:class=>"#node_class_ids", :data_source=>"/node_classes.json", :objects=>[]})
      assigns[:group_data].should include({:class=>"#node_group_ids", :data_source=>"/node_groups.json", :objects=>[]})
    end

    it 'should work when given a node name' do
      get :edit, params: { id: @node.name }

      response.should render_template('edit')
      response.should be_successful

      assigns[:node].should == @node
    end
  end

  describe '#update' do
    def do_patch
      patch :update, params: @params
    end

    before :each do
      SETTINGS.stubs(:enable_read_only_mode).returns(false)
      @node = create(:node)
      @params = { :id => @node.id, :node => @node.attributes }
    end

    it 'should fail when an invalid node id is given' do
      @params[:id] = 'unknown'
      expect { do_patch }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'should work when given a node name' do
      @params.merge!({:id => @node.name})

      do_patch
      assigns[:node].should == @node
    end

    describe 'when a valid node id is given' do

      describe 'and the data provided would make the node invalid' do
        before :each do
          @params[:node]['name'] = nil
        end

        it 'should make the node available to the view' do
          do_patch
          assigns[:node].should == @node
        end

        it 'should not save the node' do
          do_patch
          Node.find(@node.id).name.should_not be_nil
        end

        it 'should have errors on the node' do
          do_patch
          assigns[:node].errors[:name].should_not be_blank
        end

        it 'should render error' do
          do_patch
          response.should render_template('shared/_error')
        end
      end

      describe 'and the data provided make the node valid' do
        it 'should update the node with the data provided' do
          @params[:node]['description'] = 'new description'
          do_patch
          Node.find(@node.id).description.should == 'new description'
        end

        it 'should have a valid node' do
          do_patch
          assigns[:node].should be_valid
        end
      end

      it 'should response with JSON that contains redirect URL' do
        do_patch
        json_response = json_from_response_body
        response.code.should == '200'
        response_hash = JSON.parse(response.body)
        response_hash["status"].should == "ok"
        response_hash["valid"].should == "true"
        response_hash["redirect_to"].should =~ /#{node_path(@node)}$/
      end
    end

    describe "when node classification is enabled" do
      before :each do
        SETTINGS.stubs(:use_external_node_classification).returns(true)
      end

      it "should allow specification of 'parameter_attributes'" do
        @params[:node].merge! :parameter_attributes => [{:key => 'foo', :value => 'bar'}]

        do_patch

        @node.reload.parameters.to_hash.should include({'foo' => 'bar'})
      end

      it "should allow specification of node classes" do
        node_class = create(:node_class)
        @params[:node].merge! :node_class_ids => [node_class.id]

        do_patch

        @node.reload.node_classes.should == [node_class]
      end
    end

    describe "when node classification is disabled" do
      before :each do
        SETTINGS.stubs(:use_external_node_classification).returns(false)
      end

      it "should fail if parameter_attributes are specified" do
        @params[:node].merge! :parameter_attributes => [{:key => 'foo', :value => 'bar'}]

        do_patch

        response.should be_forbidden
        response.body.should =~ /Node classification has been disabled/

        @node.reload.parameters.to_hash.should_not be_present
      end

      it "should fail if node classes are specified" do
        node_class = create(:node_class)
        @params[:node].merge! :assigned_node_class_ids => [node_class.id]

        do_patch

        response.should be_forbidden
        response.body.should =~ /Node classification has been disabled/

        @node.reload.node_classes.should_not be_present
      end

      it "should not fail if node groups are specified" do
        node_group = create(:node_group)
        @params[:node].merge! :assigned_node_group_ids => [node_group.id]

        do_patch

        response.code.should == '200'
        response_hash = JSON.parse(response.body)
        response_hash["status"].should == "ok"
        response_hash["valid"].should == "true"
        response_hash["redirect_to"].should =~ /#{node_path(@node)}$/

        @node.node_groups.should == [node_group]
      end

      it "should succeed if parameter_attributes and node classes are omitted" do
        do_patch
        response.code.should == '200'
        response_hash = JSON.parse(response.body)
        response_hash["status"].should == "ok"
        response_hash["valid"].should == "true"
        response_hash["redirect_to"].should_not be_empty
      end
    end

    describe "when conflicts exist" do
      before :each do
        @node_group_a = create(:node_group, :name => 'A')
        @node_group_b = create(:node_group, :name => 'B')
      end

      describe "when global parameters conflicts exists" do
        before :each do
          @param_1 = create(:parameter, :key => 'foo', :value => '1')
          @param_2 = create(:parameter, :key => 'foo', :value => '2')

          @node_group_a.parameters << @param_1
          @node_group_b.parameters << @param_2
        end

        it "should return JSON containing valid='false'" do
          @params[:node].merge!({"assigned_node_group_ids" => ["#{@node_group_a.id},#{@node_group_b.id},"]})
          do_patch

          response = json_from_response_body
          response["status"].should == "ok"
          response["valid"].should == "false"
        end

        it "should render conflicts prompt" do
          @params[:node].merge!({"assigned_node_group_ids" => ["#{@node_group_a.id},#{@node_group_b.id},"]})
          do_patch

          response.should render_template('shared/_variable_conflicts_table')
        end

        it "should return JSON containing redirect_to URL when update is forced" do
          @params[:node].merge!({"assigned_node_group_ids" => ["#{@node_group_a.id},#{@node_group_b.id},"]})
          @params.merge!({ :force_update => "true" })
          do_patch

          response.code.should == '200'
          response_hash = JSON.parse(response.body)
          response_hash["status"].should == "ok"
          response_hash["valid"].should == "true"
          response_hash["redirect_to"].should =~ /#{node_path(@node)}$/
        end

        it "should not render conflicts prompt when update is forced" do
          @params[:node].merge!({"assigned_node_group_ids" => ["#{@node_group_a.id},#{@node_group_b.id},"]})
          @params.merge!({ :force_update => "true" })
          do_patch

          response.should_not render_template('shared/_confirm.html.haml')
        end
      end

      describe "when class parameters conflicts exists" do
        before :each do
          @node_class_a = create(:node_class, :name => 'class_a')
          @node_group_a.node_classes << @node_class_a
          @node_group_b.node_classes << @node_class_a

          @node_group_a_class_memberships_a = NodeGroupClassMembership.find_by_node_group_id_and_node_class_id(@node_group_a.id, @node_class_a.id)
          @node_group_a_class_memberships_a.parameters << create(:parameter, :key => 'foo', :value => '1')
          @node_group_b_class_memberships_a = NodeGroupClassMembership.find_by_node_group_id_and_node_class_id(@node_group_b.id, @node_class_a.id)
          @node_group_b_class_memberships_a.parameters << create(:parameter, :key => 'foo', :value => '2')
        end

        it "should return JSON containing valid='false'" do
          @params[:node].merge!({"assigned_node_group_ids" => ["#{@node_group_a.id},#{@node_group_b.id},"]})
          do_patch

          response = json_from_response_body
          response["status"].should == "ok"
          response["valid"].should == "false"
        end

        it "should render conflicts prompt" do
          @params[:node].merge!({"assigned_node_group_ids" => ["#{@node_group_a.id},#{@node_group_b.id},"]})
          do_patch

          response.should render_template('shared/_class_parameter_conflicts_table')
        end

        it "should return JSON containing redirect_to URL when update is forced" do
          @params[:node].merge!({"assigned_node_group_ids" => ["#{@node_group_a.id},#{@node_group_b.id},"]})
          @params.merge!({ :force_update => "true" })
          do_patch

          response.code.should == '200'
          response_hash = JSON.parse(response.body)
          response_hash["status"].should == "ok"
          response_hash["valid"].should == "true"
          response_hash["redirect_to"].should =~ /#{node_path(@node)}$/
        end

        it "should not render conflicts prompt when update is forced" do
          @params[:node].merge!({"assigned_node_group_ids" => ["#{@node_group_a.id},#{@node_group_b.id},"]})
          @params.merge!({ :force_update => "true" })
          do_patch

          response.should_not render_template('shared/_confirm.html.haml')
        end
      end
    end
  end

  describe "#search" do
    before :each do
      @params = {}
    end

    it "should strip empty search parameters" do
      expected_param = {'fact' => 'foo', 'comparator' => 'eq', 'value' => 'bar'}
      @params['search_params'] = [
        {'fact' => '', 'comparator' => '', 'values' => ''},
        {'fact' => 'foo', 'comparator' => '', 'values' => ''},
        {'fact' => '', 'comparator' => 'eq', 'values' => ''},
        {'fact' => '', 'comparator' => '', 'values' => 'bar'},
        expected_param,
      ]

      Node.expects(:find_from_inventory_search).with([expected_param])
      get :search, params: @params
    end

    it "should not search with no parameters" do
      @params['search_params'] = []

      Node.expects(:find_from_inventory_search).never
      get :search, params: @params
    end
  end

  describe "#hide" do
    it "should hide the node" do
      @node = create(:node)
      @node.hidden.should == false

      put :hide, params: { id: @node.name }

      response.should redirect_to(node_path(@node))
      @node.reload
      @node.hidden.should == true
    end
  end

  describe "#unhide" do
    it "should unhide the node" do
      @node = create(:node, :hidden => true)
      @node.hidden.should == true

      put :unhide, params: { id: @node.name }

      response.should redirect_to(node_path(@node))
      @node.reload
      @node.hidden.should == false
    end
  end

  describe "#facts" do
    before :each do
      @time = Time.now
      @node = create(:node, :name => 'testnode')
      Node.any_instance.stubs(:facts).returns({:timestamp => @time, :values => {"foo" => "1", "bar" => "2"}})
    end

    def do_get
      get :facts, params: { id: @node.name }
    end

    it "should fail gracefully when connections are refused" do
      Node.any_instance.stubs(:facts).raises(Errno::ECONNREFUSED)

      do_get
      response.body.should =~ /Could not retrieve facts from inventory service: Connection refused/
    end

    it "should fail gracefully when other errors occur" do
      Node.any_instance.stubs(:facts).raises("some error")

      do_get
      response.body.should =~ /Could not retrieve facts from inventory service: some error/
    end

    it "should render a table when facts are fetched" do
      do_get
      response.body.should =~ /<table.*>/
    end

    it "should include the inventory timestamp in the rendered table" do
      do_get
      response.body.should =~ /Current inventory for testnode as of #{@time}/
    end
  end

  describe "#reports" do
    before :each do
      @node = create(:node)
      Node.stubs(:find_by_name! => @node)
      Report.stubs(:assign_to_node => false)
      @report = Report.create_from_yaml(report_yaml_with(:host => @node.name))
      @node.reports = [@report]
    end

    context "for HTML" do
      before { get :reports, params: { id: @node.name } }

      specify { response.should be_successful }

      it "should be paginated" do
        assigns[:reports].should respond_to(:paginate)
      end
    end
  end

  # Relies on #action returning name of a NodesController action, e.g. as "successful".
  describe "#scoped_index" do
    shared_examples_for "a scoped_index action" do
      context "as HTML" do
        before { get action, params: action_params }

        specify { response.should be_successful }

        it "should assign only appropriate records" do
          assigns[:nodes].size.should == 1
          assigns[:nodes].first.name.should == "foo"
        end

        # NOTE: Once upon a time, these were paginated but were breaking the graphs
        it "should not be paginated" do
          assigns[:nodes].should_not be_a_kind_of(WillPaginate::Collection)
        end
      end

      context "as YAML" do
        context "when using node classification" do
          before :each do
            SETTINGS.stubs(:use_external_node_classification).returns(true)
            get action, params: action_params.merge(format: 'yaml')
          end

          specify { response.should be_successful }

          it "should assign only appropriate records" do
            assigns[:nodes].size.should == 1
          end

          it "should not be paginated" do
            assigns[:nodes].should_not be_a_kind_of(WillPaginate::Collection)
          end

          it "should return YAML" do
            struct = yaml_from_response_body
            struct.size.should == 1
            struct.first["name"].should == "foo"
          end
        end
      end
    end

    describe "#unreported" do
      before :each do
        @node = create(:node, :name => 'foo')
        @hidden_node = create(:node, :name => 'bar', :hidden => true)
      end

      let(:action) { "unreported" }
      let(:action_params) { {} }

      it_should_behave_like "a scoped_index action"
    end

    describe "#hidden" do
      before :each do
        @node = create(:node, :name => 'foo', :hidden => true)
        @unhidden_node = create(:node, :name => 'bar')
      end

      let(:action) { "hidden" }
      let(:action_params) { {} }

      it_should_behave_like "a scoped_index action"
    end
  end

  describe 'read-only mode' do

    let(:node) { create(:node) }

    ['configuration file', 'Rack middleware'].each do |source|
      describe "when set by the #{source}" do
        before :each do
          SETTINGS.stubs(:enable_read_only_mode).returns(source == 'configuration file')
          session.expects(:[]).with('ACCESS_CONTROL_ROLE').returns('READ_ONLY') if source == 'Rack middleware'
          # Raising the ReadOnlyEnabledError exception will create a session[:flash] error entry, which we stub (but not expects)
          session.stubs(:[]).with('flash').returns(nil)
        end

        it "should raise an error when calling 'new'" do
          expect { get :new }.to raise_error(ReadOnlyEnabledError)
        end

        it "should raise an error calling 'edit'" do
          expect { get :edit, params: { id: node.name } }.to raise_error(ReadOnlyEnabledError)
        end

        it "should raise an error when calling 'update'" do
          params = { :id => node.id, :node => node.attributes }
          expect { put :update, params: params }.to raise_error(ReadOnlyEnabledError)
        end

        it "should raise an error when calling 'create'" do
          expect { post :create, params: { node: { name: 'foo' } } }.to raise_error(ReadOnlyEnabledError)
        end
      end
    end
  end
end
