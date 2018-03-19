`timescale 1ns/1ns

`define CLOCKPERIOD 10
//`define INITMEMSIZE 2000 //comment out if mems are initialized in FPGA synthesis

//`define MODELSIM
`define VIVADO

`define MNIST //Dataset
`define NIN 784 //Number of inputs AS IN DATASET
`define NOUT 10 //Number of outputs AS IN DATASET
`define TC 10000 //Training cases to be considered in 1 epoch
`define TTC 10*`TC //Total training cases over all epochs
`define CHECKLAST 1000 //How many last inputs to check for accuracy

/*`define SMALLNET //Dataset
`define NIN 64 //Number of inputs AS IN DATASET
`define NOUT 4 //Number of outputs AS IN DATASET
`define TC 2000 //Training cases to be considered in 1 epoch
`define TTC 1*`TC //Total training cases over all epochs
`define CHECKLAST 1000 //How many last inputs to check for accuracy*/

module tb_DNN #(
	parameter width_in = 8,
	parameter width = 12,
	parameter int_bits = 3,
	localparam frac_bits = width-int_bits-1,
	
	parameter L = 3,
	parameter [31:0] actfn [0:L-2] = '{0,0},
	parameter costfn = 1,
	parameter ec = 2,
	
	parameter Eta = 2.0**(-4) //Should be a power of 2. Value between 2^(-frac_bits) and 1. DO NOT WRITE THIS AS 2**x, it doesn't work without 2.0
);

`ifdef MNIST
	parameter [31:0] n [0:L-1] = '{1024, 64, 16}; //No. of neurons in every layer
	parameter [31:0] fo [0:L-2] = '{8, 8}; //Fanout of all layers except for output
	parameter [31:0] fi [0:L-2] = '{128, 32}; //Fanin of all layers except for input
	parameter [31:0] z [0:L-2] = '{512, 32}; //Degree of parallelism of all junctions. No. of junctions = L-1
`elsif SMALLNET
	parameter [31:0] n [0:L-1] = '{64, 16, 4};
	parameter [31:0] fo [0:L-2] = '{2, 2};
	parameter [31:0] fi [0:L-2] = '{8, 8};
	parameter [31:0] z [0:L-2] = '{32, 8};
`endif
	
	localparam cpc =  n[0] * fo[0] / z[0] + 2;
	genvar gv_i;
	
	
	////////////////////////////////////////////////////////////////////////////////////
	// DNN instantiation
	////////////////////////////////////////////////////////////////////////////////////
	logic clk = 1;
	logic reset = 1;
	logic [$clog2(frac_bits+2)-1:0] etapos;
	logic [width_in-1:0] act0 [z[0]/fo[0]-1:0];
	logic [z[L-2]/fi[L-2]-1:0] ans0;
	logic [z[L-2]/fi[L-2]-1:0] ansL;
	logic [n[L-1]-1:0] actL_alln;
	
	DNN #(
		.width_in(width_in),
		.width(width), 
		.int_bits(int_bits),
		.L(L),
		.actfn(actfn),
		.costfn(costfn),
		.ec(ec),
		.n(n),
		.fo(fo), 
		.fi(fi), 
		.z(z)
	) DNN (
		.clk,
		.reset,
		.etapos0(etapos), 
		.act0,
		.ans0, 
		.ansL,
		.actL_alln
	);
	////////////////////////////////////////////////////////////////////////////////////


	////////////////////////////////////////////////////////////////////////////////////
	// Set Clock, Cycle Clock, Reset, etapos
	////////////////////////////////////////////////////////////////////////////////////
	initial begin
		//#1 reset = 1;	
		#(cpc*L*`CLOCKPERIOD + 1) reset = 0;
		//max shift logic depth is cpc*(L-1). So lower reset after even the deepest DFFs in the shift regs have time to latch 0 from previous stages
	end

	// Get etapos from Eta
	integer etaloop;
	logic found = 0;
	logic [width-1:0] eta;
	initial begin
		eta = Eta * (2 ** frac_bits); //convert the Eta to fix point
		for (etaloop=0; etaloop<=frac_bits; etaloop=etaloop+1) begin
			if (eta[frac_bits-etaloop] && !found) begin
				etapos = etaloop+1;
				found = 1;
			end
		end
	end

	always #(`CLOCKPERIOD/2) clk = ~clk;
	
	logic cycle_clk;
	logic [$clog2(cpc)-1:0] cycle_index;
	cycle_block_counter #(
		.cpc(cpc)
	) cycle_counter (
		.clk,
		.reset,
		.cycle_clk,
		.count(cycle_index)
	);
	////////////////////////////////////////////////////////////////////////////////////


	////////////////////////////////////////////////////////////////////////////////////
	// Data import and training cases pre-processing	
	// This is specific to 1024 inputs and 16 outputs
	/* train_input.dat contains 50000 MNIST patterns. Each pattern contain 28*28 pixels which is 8 bit gray scale.
		1 line is one pattern with 784 8bit hex. Values from 784-1023 are set to 0 */
	/* train_idealout.dat is the data set for 50000 correct results of training data. There are 10 bits one-hot representing 10 numbers from 0-9.
		1 line is one pattern with 10 one-hot binary. Values from 10-15 are set to 0 */
	
	/* SIMULATOR NOTES:
	*	Modelsim can read a input file with spaces and assign it in natural counting order
		Eg: The line a b c d e f g h i j when written to an input vector [9:0], will be written as [0]=a, [1]=b, ..., [9]=j
		This is opposite to the opposite counting order naturally followed in hardware, and is possible because of the spaces in the input file
	*	Vivado cannot read an input file with spaces, so when it reads a packed input file, it assigns in hardware order (i.e. opposite counting order)
		Eg: The line abcdefghij when written to an input vector [9:0], will be written as [9]=a, [8]=b, ..., [0]=j
	*	The Modelsim version was done first, it works and also shows up nicely in the output log files since counting order is natural
		So we will force the Vivado version to have natural counting order in hardware
	* SIDE NOTE: Please keep only 1 copy of the data (Gaussian lists and training I/O) in the Verilog folder. Don't create extra for Vivado */
	////////////////////////////////////////////////////////////////////////////////////	
	logic [$clog2(`TC)-1:0] sel_tc = 0; //MUX select to choose training case each block cycle
	logic [$clog2(cpc-ec)-1:0] sel_network; //MUX select to choose which input/output pair to feed to network within a block cycle
	logic [n[L-1]-1:0] ans0_tc; //Complete ideal output for 1 training case, i.e. No. of output neurons x 1 x 1
	logic [width_in*n[0]-1:0] act0_tc; //Complete act input for 1 training case, i.e. No. of input neurons x 8 x 1
	logic [width_in*z[0]/fo[0]-1:0] act0_packed; //Output of mux_packed_unsigned
	
	/* Uncomment if mems are not initialized, such as for sim
	logic signed [width-1:0] memJ1 [`INITMEMSIZE-1:0]; //1st junction weight memory
	logic signed [width-1:0] memJ2 [`INITMEMSIZE-1:0]; //2nd junction weight memory
	initial begin
		$readmemb("./gaussian_list/s136_frc7_int2.dat", memJ1);
		$readmemb("./gaussian_list/s40_frc7_int2.dat", memJ2);
	end
	*/
	
	// Read data from files
	`ifdef MNIST
		`ifdef MODELSIM
			logic [width_in-1:0] act_mem [`TC-1:0][`NIN-1:0]; //inputs
			logic ans_mem [`TC-1:0][`NOUT-1:0]; //ideal outputs
			initial begin
				$readmemb("./data/mnist/train_idealout_spaced.dat", ans_mem);
				$readmemh("./data/mnist/train_input_spaced.dat", act_mem);
			end   
		`elsif VIVADO
			logic [width_in-1:0] act_mem[`TC-1:0][0:`NIN-1]; //flipping only occurs in the 784 dimension
			logic ans_mem[`TC-1:0][0:`NOUT-1]; //flipping only occurs in the 10 dimension
			initial begin
				$readmemb("./data/mnist/train_idealout.dat", ans_mem);
				$readmemh("./data/mnist/train_input.dat", act_mem);
			end
		`endif
	`elsif SMALLNET
		`ifdef MODELSIM
			logic [width_in-1:0] act_mem[`TC-1:0][`NIN-1:0]; //inputs
			logic ans_mem[`TC-1:0][`NOUT-1:0]; //ideal outputs
			initial begin
				$readmemb("./data/smallnet/train_idealout_4_spaced.dat", ans_mem);
				$readmemh("./data/smallnet/train_input_64_spaced.dat", act_mem);
			end       
		`elsif VIVADO
			logic [width_in-1:0] act_mem[`TC-1:0][0:`NIN-1]; //flipping only occurs in the 784 dimension
			logic ans_mem[`TC-1:0][0:`NOUT-1]; //flipping only occurs in the 10 dimension
			initial begin
				$readmemb("./data/smallnet/train_idealout_4.dat", ans_mem);
				$readmemh("./data/smallnet/train_input_64.dat", act_mem);
			end
		`endif	
	`endif

	//Code to select training case via sel_tc is give later under always @(posedge cycle_clk)
	
	//Take relevant portion of data
	generate for (gv_i = 0; gv_i<n[0]; gv_i++) begin: input_assign
		assign act0_tc[width_in*(gv_i+1)-1:width_in*gv_i] = (gv_i<`NIN) ? act_mem[sel_tc][gv_i] : '0;
	end for (gv_i = 0; gv_i<n[L-1]; gv_i++) begin: output_assign
		assign ans0_tc[gv_i] = (gv_i<`NOUT) ? ans_mem[sel_tc][gv_i] : 0;
	end
	endgenerate
	
	//MUX select for data
	assign sel_network = cycle_index[$clog2(cpc-ec)-1:0]-ec;
	/* cycle_index goes from 0-17, so its 4 LSB go from 0 to cpc-3 then 0 to 1
	* But nothing happens in the last 2 cycles since pipeline delay is 2
	* So take values of cycle_index from 0-15 and subtract 2 to make its 4 LSB go from 14-15, then 0-13
	* Note that the jumbled order isn't important as long as all inputs from 0-15 are fed */
			
	//Choose the required no. of ideal outputs for feeding to DNN
	mux_packed_unsigned #(
		.width(z[L-2]/fi[L-2]), 
		.N(n[L-1]*fi[L-2]/z[L-2]) //This is basically cpc-ec
	) muxps_idealoutput_feednetwork (
		.in_package(ans0_tc),
		.sel(sel_network),
		.out(ans0)
	);

	//Choose the required no. of act inputs for feeding to DNN
	mux_packed_unsigned #(
		.width(width_in*z[0]/fo[0]), 
		.N(n[0]*fo[0]/z[0]) //This is basically cpc-ec
	) muxps_actinput_feednetwork (
		.in_package(act0_tc),
		.sel(sel_network),
		.out(act0_packed)
	);
	
	// Unpack DNN inputs before feeding
	generate for (gv_i=0; gv_i<z[0]/fo[0]; gv_i++) begin: unpack_act0
		assign act0[gv_i] = act0_packed[(gv_i+1)*width_in-1 : gv_i*width_in];
	end
	endgenerate
	////////////////////////////////////////////////////////////////////////////////////


	////////////////////////////////////////////////////////////////////////////////////
	// Performance Evaluation Variables
	////////////////////////////////////////////////////////////////////////////////////
	integer  num_train = 0, //Number of the current training case
				epoch = 1,
				q, //loop variable
				correct, //signals whether current training case is correct or not
				recent = 0, //counts #correct in last 1000 training cases
				crt[`CHECKLAST:0], //stores last 1000 results - each result is either 1 or 0
				crt_pt=0, //points to where current training case result will enter. Loops around on reaching 1000
				total_correct = 0, //Total number of correct accumulated over training cases
				log_file;
	real 		EMS; //Expected mean square error between actL_alln and ansL of all neurons in output layer
	/*real error_rate = 0;
	* Let e = sum over all output neurons |ansL-actL|, where actL is the unthresholded output of the last layer
	* Then e is basically giving the L1 norm over all output neurons of a particular training case
	* error_rate computes average of e over the last 100 training cases, i.e. moving average */
	
	//The following variables store information about all output neurons
	real  actL_alln_calc[n[L-1]-1:0], //Actual 32-bit output of network
			//actans_diff[cpc-3:0],
			//spL[n[L-1]-1:0],
			//zL[n[L-1]-1:0], //output layer z, i.e. just before taking final sigmoid
			actans_diff_alln_calc[n[L-1]-1:0]; //act-ans
	integer ansL_alln_calc[n[L-1]-1:0]; //Ideal output ans0_tc
	
	//The following variables store information of the 0th cycle (when cycle_index = 2 out of 17) as fed to the update processor
	real wt1 [cpc-ec-1:0]; //all hidden layer weights from 0th mem
	real bias2 [cpc-ec-1:0]; //all output layer biases from 0th bias mem, i.e. zth wt mem (since z to z+z/fi-1 wt mems are actually bias mems)
	real act1[z[L-2]-1:0]; //activations (which get multiplied by deltas for weight updates)
	////////////////////////////////////////////////////////////////////////////////////


	////////////////////////////////////////////////////////////////////////////////////
	// Probe DNN signals
	// x/2.0**frac_bits is used to convert any value x which has frac_bits number of fractional bits in binary to decimal
	////////////////////////////////////////////////////////////////////////////////////
	always @(negedge clk) begin
		if (cycle_index>=ec) begin //Actual output, ideal output
			for (q=0; q<z[L-2]/fi[L-2]; q++) begin
				actL_alln_calc[(cycle_index-ec)*z[L-2]/fi[L-2]+q] = DNN.actL1[q] / 2.0**frac_bits;
				ansL_alln_calc[(cycle_index-ec)*z[L-2]/fi[L-2]+q] = ansL[q]; //Division is not required because it is not in width form
				actans_diff_alln_calc[(cycle_index-ec)*z[L-2]/fi[L-2]+q] = DNN.output_layer.del[q] / 2.0**frac_bits;
			end
			wt1[cycle_index-ec] = DNN.hidden_layer_1.hidden_wb_mem.data_outB[0] / 2.0**frac_bits;
			bias2[cycle_index-ec] = DNN.hidden_layer_1.hidden_wb_mem.data_outB[z[L-2]] / 2.0**frac_bits;
		end
		/*if (cycle_index>0 && cycle_index<=cpc-ec) begin //z of output layer
			zL[cycle_index-1] = DNN.hidden_layer_1.FF_processor.sigmoid_function_set[0].s_function.s/2.0**frac_bits;
		end*/
	end
	////////////////////////////////////////////////////////////////////////////////////
	
	
	////////////////////////////////////////////////////////////////////////////////////
	// Performance evaluation and display
	////////////////////////////////////////////////////////////////////////////////////
	initial begin
		log_file = $fopen("results_log.dat"); //Stores a lot of info
		for(q=0; q<=`CHECKLAST; q=q+1) crt[q]=0; //initialize all 1000 places to 0
	end

	always @(posedge cycle_clk) begin
		#0; //let everything in the circuit finish before starting performance eval
		num_train = num_train + 1;
		sel_tc = (sel_tc == `TC-1)? 0 : sel_tc + 1;

		recent = recent - crt[crt_pt]; //crt[crt_pt] is the value about to be replaced 
		correct = 1; //temporary placeholder
		for (q=0; q<n[L-1]; q=q+1) begin
			if (actL_alln[q]!=ansL_alln_calc[q]) correct=0; //any mismatch in output neurons means wrong
		end
		crt[crt_pt] = correct;
		recent = recent + crt[crt_pt]; //Update recent with value just stored
		crt_pt = (crt_pt==`CHECKLAST)? 0 : crt_pt+1;
		total_correct = total_correct + correct;
		
		EMS = 0;
		for (q=0; q<n[L-1]; q=q+1)
			EMS = actans_diff_alln_calc[q]*actans_diff_alln_calc[q] + EMS;
		EMS = EMS * 100;
	
	
		// Transcript display - basic stats
		$display("Case number = %0d, correct = %0d, recent_%0d = %0d, EMS = %5f", num_train, correct, `CHECKLAST, recent, EMS); 

		// Write to log file - Everything
		$fdisplay (log_file,"-----------------------------train: %d", num_train);
		$fwrite (log_file, "ideal       output:");
		for(q=0; q<n[L-1]; q=q+1) $fwrite (log_file, "\t %5d", ansL_alln_calc[q]); $fwrite (log_file, "\n");
		$fwrite (log_file, "actual      output:");
		for(q=0; q<n[L-1]; q=q+1) $fwrite (log_file, "\t %5d", actL_alln[q]); $fwrite (log_file, "\n");
		$fwrite (log_file, "actual real output:");
		for(q=0; q<n[L-1]; q=q+1) $fwrite (log_file, "\t %1.4f", actL_alln_calc[q]); $fwrite (log_file, "\n");
		$fwrite (log_file, "actualreal - ideal:");
		for(q=0; q<n[L-1]; q=q+1) $fwrite (log_file, "\t %1.4f", actans_diff_alln_calc[q]); $fwrite (log_file, "\n");
		//$fwrite (log_file, "z:            ");
		//for(q=0; q<n[L-1]; q=q+1) $fwrite (log_file, "\t %1.4f", zL[q]); $fwrite (log_file, "\n");
		//$fwrite (log_file, "spL:          ");
		//for(q=0; q<n[L-1]; q=q+1) $fwrite (log_file, "\t %1.4f", spL[q]); $fwrite (log_file, "\n");
		//$fwrite (log_file, "act1:     ");
		//for(q=0; q<z[L-2]; q=q+1) $fwrite (log_file, "\t %1.3f", act1[q]); $fwrite (log_file, "\n");
		$fwrite (log_file, "Junction  12 weights from 0th wbmem:");
		for(q=0; q<cpc-ec; q=q+1) $fwrite (log_file, "\t %1.3f", wt1[q]); $fwrite (log_file, "\n");
		$fwrite (log_file, "Output neuron biases from zth wbmem:");
		for(q=0; q<cpc-ec; q=q+1) $fwrite (log_file, "\t %1.3f", bias2[q]); $fwrite (log_file, "\n");
		//$fwrite (log_file, "delta_w12:     ");
		//for(q=0; q<z[L-2]; q=q+1) $fwrite (log_file, "\t %1.3f", del_wb1[q]); $fwrite (log_file, "\n");
		//$fwrite (log_file, "delta_b2:     ");
		//for(q=z[L-2]; q<z[L-2]+z[L-2]/fi[L-2]; q=q+1) $fwrite (log_file, "\t %1.3f", del_wb1[q]); $fwrite (log_file, "\n");
		$fdisplay(log_file, "correct = %0d, recent_%4d = %3d, EMS = %5f", correct, `CHECKLAST, recent, EMS);
		if (sel_tc == 0) begin
			$fdisplay(log_file, "\nFINISHED TRAINING EPOCH %0d", epoch);
			$fdisplay(log_file, "Total Correct = %0d\n", total_correct);
			epoch = epoch + 1;
		end
		
		// Stop conditions
		if (num_train==`TTC) $stop;
		// #1000000 $stop;
	end
	////////////////////////////////////////////////////////////////////////////////////
	
	/* always @(posedge clk) begin
		if (cycle_index > 1 && actL_alln != ansL) tc_error = 1; //Since output is obtained starting from cycle 2 up till cycle (cpc-1)
		if( cycle_index > 1)
			// Need to divide actL by 2**frac_bits to get result between 0 and 1
			if(ansL) error_rate = error_rate + ansL - DNN.actL1/(2**frac_bits); //ansL = 1, so |ansL-actL| = 1-actL
			else error_rate = error_rate + DNN.actL1/(2**frac_bits); //ansL = 0, so |ansL-actL| = actL
	end */
endmodule