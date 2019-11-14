#include <time.h>
// includes, system
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <malloc.h>
#include <math.h>
#include "cublas.h"
// includes, project
#include <cufft.h>
//#include <cutil_inline.h>
//#include <shrQATest.h>
#include "su.h"
#include "segy.h"
#include "Complex.h"
#include <cuda_runtime.h>
#include "cublas_v2.h"
#include <helper_functions.h>
#include <helper_cuda.h>

//#include "kexuan4.h"
#include "zzzzz"
#include "3D_zzzzz"

#include "3D_elastic_modeling_parameter"
#include "3D_elastic_modeling_parameter_sh"

#include "3D_elastic_modeling_typedef_struct"

#include "3D_elastic_modeling_kernel.cu"

#include "3D_output_file.cu"

#include "3D_forward_or_back_together.cu"



//#include "./2D-function/elastic_2D_kernel_1.cu"
//#include "./2D-function/elastic_2D_kernel_2.cu"
//#include "./2D-function/elastic_adjoint_equation.cu"
//#include "./2D-function/viscoelastic_equation.cu"




/*********************** self documentation ******************************/
char *sdoc[] = {
"                                                                        ",
" this is a program to model elastic zhengyan by FD ",
" this was created by zhange in Daqing in 2015-09-06 ",
" Prestack visco/elastic LSRTM in 2017-8-31 ",
" Prestack           Prestack               Prestack"
" 3D elastic modeling in 2018-1-30"
"                                                                        ",
NULL};
/**************** end self doc *******************************************/
segy tr;

//static time_t t1,t2;
//----------------------------- main -------------------------------------------
int main(int argc, char **argv)
{
		
		//requestdoc(1);
		initargs(argc,argv);

		elastic_modeling_parameter_input();

		checkCudaErrors(cudaSetDevice(GPU_start));

		cublasHandle_t cubhandle;  

    		cublasStatus_t cubStatus = CUBLAS_STATUS_SUCCESS;
 
		cubStatus = cublasCreate(&cubhandle);

		//CUBLAS_ERROR_CHECK(cubStatus)


		logfile=fopen("log.txt","ab");//remember to free log file
		if(join_vs==0)						fprintf(logfile,"vs has not been joined,thus they can be obtained by empirical formula\n");
		else								fprintf(logfile,"vs has been joined\n");
		if(join_den==0)						fprintf(logfile,"den has not been joined,thus they can be obtained by empirical formula\n");
		else								fprintf(logfile,"density has been joined\n");

		fclose(logfile);

		//**********PREPARE WORKS**********
				
		wavelet=make_ricker_new(freq,dt/1000.0,&wavelet_length);
		wavelet_integral=make_ricker_new(freq,dt/1000.0,&wavelet_length);
		wavelet_half=wavelet_length/2;
		//wavelet=alloc1float(lt);
		//wavelet_integral=alloc1float(lt);
		//set_zero_1d(wavelet,lt);
		//set_zero_1d(wavelet_integral,lt);
		//make_ricker_better(wavelet,freq,dt,lt);
		//make_ricker_better(wavelet_integral,freq,dt,lt);
		//make_ricker_initial(wavelet,freq,dt,lt);
		//make_ricker_initial(wavelet_integral,freq,dt,lt);
		//wavelet_length=lt;
		//wavelet_half=wavelet_length/2;
		write_file_1d(wavelet,wavelet_length,"./someoutput/wavelet.bin");
		warn("Ricker wavelet is set   wavelet_length=%d,wavelet_half=%d\n",wavelet_length,wavelet_half);

		
		coe_opt=alloc1float(radius+1);
		make_coe_optimized_new(coe_opt);
		write_file_1d(coe_opt,radius+1,"./someoutput/coe_opt.bin");
		warn("make_coe_optimized has been done!\n");

///////////////////**************************CUDA-applied device count
		//******initializing GPU information******

		GPUdevice mgdevice[MAX_GPU_COUNT];///////////开辟 最大GPU个数的GPUdevice成员!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
		
		checkCudaErrors(cudaGetDeviceCount(&GPU_Read));///////得到目前GPU卡号？
		if(GPU_Read>MAX_GPU_COUNT)
				GPU_Read=MAX_GPU_COUNT;
		warn("CUDA-capable device count: %i",GPU_Read);///输出可用卡号

		/*if(GPU_switch==0)
		{
				GPU_N=GPU_Read;
				GPU_start=0;
		}
		else if(GPU_switch==1)
		{
				if(GPU_start+GPU_N > GPU_Read)
						GPU_N=GPU_N-(GPU_start+GPU_N-GPU_Read);
		}
		warn("CUDA-applied device count: %i",GPU_Read);*/

		
		for(int igpu=0;igpu<GPU_N;igpu++)
		{
				gpuid[igpu]=GPU_start+igpu;
				warn("gpuid[%d]=%d",igpu,gpuid[igpu]);///开始卡号到截至卡号分别是多少？？？
		}
///////////////////**************************CUDA-applied device count

		
		nnx=nx+bl+br;//nnx=nx+boundary_left+boundary_right;
		nny=ny+bf+bb;//nny=ny+boundary_front+boundary_back;
		nnz=nz+bu+bd;//nnz=nz+boundary_up+boundary_down;

		gpu_memory_size=nnx*nny*nnz*(sizeof(float))/1024.0/1024.0;
		warn("nnx=%d,nny=%d,nnz=%d\n,gpu_memory_size of one wavefield=%f",nnx,nny,nnz,gpu_memory_size);
		logfile=fopen("log.txt","ab");//remember to free log file
		fprintf(logfile,"nnx=%d,nny=%d,nnz=%d\n,gpu_memory_size of one wavefield=%f\n",nnx,nny,nnz,gpu_memory_size);
		fclose(logfile);

		//******initializing GPU's cards******
		nnz_device=nnz/GPU_N;/////////nnz是nz已经加载PML边界的大小
		if(nnz%GPU_N!=0) nnz_device+=1;///////////////////////分块，沿着nz方向
		nnz_residual=nnz_device*GPU_N-nnz;
		nnz_device_append=nnz_device+2*radius;///////////////每一块卡需要处理z方向的大小，这里需要加载2*半径，用于数据交换？？？？
		warn("nnz_device=%d,nnz_residual=%d,nnz_device_append=%d",nnz_device,nnz_residual,nnz_device_append);//////////////////分块后的结果

		nnx_radius=nnx-2*radius;
		nny_radius=nny-2*radius;
		nnz_radius=nnz_device_append-2*radius;
		warn("nnx_radius=%d,nny_radius=%d,nnz_radius=%d",nnx_radius,nny_radius,nnz_radius);

		for(int i=0;i<GPU_N;i++)
		{
				checkCudaErrors(cudaSetDevice(gpuid[i]));
				for(int j=0;j<GPU_N;j++)
						if(i!=j)
								checkCudaErrors(cudaDeviceEnablePeerAccess(gpuid[j],0));////////////P2P的作用是不是卡与剩余所有的卡之间能否交换,GPU_start：shi用哪个卡激活??????
								//checkCudaErrors(cudaDeviceEnablePeerAccess(gpuid[j],0));////////////P2P的作用是不是卡与剩余所有的卡之间能否交换
		}
		warn("P2P set over!");

		/* creat timing variables on device */
		cudaEvent_t start, stop;
  		cudaEventCreate(&start);	
		cudaEventCreate(&stop);

		dim3 dimBlock(32,16);

		dim3 dimGridwf_append((nnx+dimBlock.x-1)/dimBlock.x,(nny+dimBlock.y-1)/dimBlock.y,nnz_device_append);//////单块卡的整个空间
		
		dim3 dimGridwf_radius((nnx_radius+dimBlock.x-1)/dimBlock.x,(nny_radius+dimBlock.y-1)/dimBlock.y,nnz_radius);///单块卡的整个空间减去半径
		
		dim3 dimGrid_rec_lt_x_y((receiver_num_x+dimBlock.x-1)/dimBlock.x,(receiver_num_y+dimBlock.y-1)/dimBlock.y);

		dim3 dimGrid_rec_lt_x_z((receiver_num_x+dimBlock.x-1)/dimBlock.x,(receiver_num_z+dimBlock.y-1)/dimBlock.y);///seismic process and receive
		
		//******initializing GPU memory******
		for(int i=0;i<GPU_N;i++)
		{
				checkCudaErrors(cudaSetDevice(gpuid[i]));/////检测卡

				checkCudaErrors(cudaStreamCreate(&mgdevice[i].stream));/////检测流

				allocate_typedef_struct(mgdevice,i);

				set_zero_typedef_struct_wavefield(mgdevice,i);
		}
		warn("initializing GPU memory has been done!");

		checkCudaErrors(cudaDeviceSynchronize());////所有卡做到完，在进行下一步？

		obs_shot_x_all=alloc3float(receiver_num_x,receiver_num_y,lt);	set_zero_3d(obs_shot_x_all,receiver_num_x,receiver_num_y,lt);
		obs_shot_y_all=alloc3float(receiver_num_x,receiver_num_y,lt);	set_zero_3d(obs_shot_y_all,receiver_num_x,receiver_num_y,lt);
		obs_shot_z_all=alloc3float(receiver_num_x,receiver_num_y,lt);	set_zero_3d(obs_shot_z_all,receiver_num_x,receiver_num_y,lt);

/////////////////////read velocity and att	
		checkCudaErrors(cudaMallocHost(&wf_3d,nnx*nny*nnz*sizeof(float)));	cudaMemset(wf_3d,0,nnx*nny*nnz*sizeof(float));///output_3d_wavefiled or others	

		checkCudaErrors(cudaMallocHost(&velocity_pml,nnx*nny*nnz*sizeof(float)));	cudaMemset(velocity_pml,0,nnx*nny*nnz*sizeof(float));
		checkCudaErrors(cudaMallocHost(&velocity1_pml,nnx*nny*nnz*sizeof(float)));	cudaMemset(velocity1_pml,0,nnx*nny*nnz*sizeof(float));
		checkCudaErrors(cudaMallocHost(&density_pml,nnx*nny*nnz*sizeof(float)));	cudaMemset(density_pml,0,nnx*nny*nnz*sizeof(float));


		get_real_model_parameter();

		warn("real model parameter has been done!");	
		
		
		checkCudaErrors(cudaMallocHost(&att_pml,nnx*nny*nnz*sizeof(float)));	cudaMemset(att_pml,0,nnx*nny*nnz*sizeof(float));
		coe_att=3.0/2.0*2500*3.0/(bu*1.0);	warn("coe_att=%f!",coe_att);

		coe_attenuation_3d_new2(att_pml,nx,ny,nz,bu,bd,bl,br,bf,bb,coe_att);
		output_file_xyz("./someoutput/att_all.bin",att_pml,nnx,nny,nnz);
		output_file_xyz_boundary("./someoutput/cut-att.bin",att_pml,nx,ny,nz,bl,bf,bu,nnx,nny,nnz);
		warn("attenation has been done!");

		seperate_vel_att1(mgdevice);///////////////////////////////////////将速度模型和衰减参数分块分别给CPU数组

		checkCudaErrors(cudaDeviceSynchronize());

		if(nnz_residual!=0)
		{
			checkCudaErrors(cudaSetDevice(gpuid[GPU_N-1]));
			expand_nnz_residual(mgdevice[GPU_N-1].density_h,nnx,nny,nnz_device_append,nnz_residual);
			expand_nnz_residual(mgdevice[GPU_N-1].velocity1_h,nnx,nny,nnz_device_append,nnz_residual);
			expand_nnz_residual(mgdevice[GPU_N-1].velocity_h,nnx,nny,nnz_device_append,nnz_residual);
			//sprintf(filename,"./someoutput/density_%d.bin",GPU_N-1);
			//output_3d(filename,mgdevice[GPU_N-1].density_h,nnx,nny,nnz_device_append);			
		}

		elastic_modeling_parameter_cpu_to_gpu(mgdevice);//////////////////////分别将分块的数据传递给对应卡的GPU数组。

		checkCudaErrors(cudaDeviceSynchronize());


/////////////////////////////////////RTM elastic parameter
		
		if(RTM!=0)///////////////////RTM=0, only to implement 3D elastic modeling
		{
			get_smoothed_model_parameter();

			seperate_vel_att1(mgdevice);///////////////////////////////////////将速度模型和衰减参数分块分别给CPU数组

			checkCudaErrors(cudaDeviceSynchronize());

			if(nnz_residual!=0)
			{
				checkCudaErrors(cudaSetDevice(gpuid[GPU_N-1]));
				expand_nnz_residual(mgdevice[GPU_N-1].density_h,nnx,nny,nnz_device_append,nnz_residual);
				expand_nnz_residual(mgdevice[GPU_N-1].velocity1_h,nnx,nny,nnz_device_append,nnz_residual);
				expand_nnz_residual(mgdevice[GPU_N-1].velocity_h,nnx,nny,nnz_device_append,nnz_residual);
				//sprintf(filename,"./someoutput/density_%d.bin",GPU_N-1);
				//output_3d(filename,mgdevice[GPU_N-1].density_h,nnx,nny,nnz_device_append);			
			}

			elastic_RTM_parameter_cpu_to_gpu(mgdevice);//////////////////////分别将分块的数据传递给对应卡的GPU数组。

			checkCudaErrors(cudaDeviceSynchronize());

			warn("smoothed model parameter has been done!");
		}	
		

		coe_x=dt/(1000.0*dx);
		coe_y=dt/(1000.0*dy);
		coe_z=dt/(1000.0*dz);

/////////////////////////////********************************////////////////////////
		
		warn("\nElastic modeling is beginning\nElastic modeling is beginning\nElastic modeling is beginning\n");
		

		
			for(isz=0;isz<shot_num_z;isz++)
			{
				for(isy=0;isy<shot_num_y;isy++)
				{
					for(isx=0;isx<shot_num_x;isx++)
					{
						cudaEventRecord(start);/* record starting time */

						for(int i=0;i<GPU_N;i++)
						{
							checkCudaErrors(cudaSetDevice(gpuid[i]));
							//test_exchange_device(mgdevice);///////////////////////////////////////test_exchange_device(mgdevice);
							set_zero_typedef_struct_wavefield(mgdevice,i);
						}
						checkCudaErrors(cudaDeviceSynchronize());////所有卡做到完，在进行下一步？
						
						sx_real=shot_start_x+isx*shot_interval_x;
						sy_real=shot_start_y+isy*shot_interval_y;
						sz_real=shot_start_z+isz*shot_interval_z;

						choose_ns=(sz_real+bu)/nnz_device;

						rx_max=receiver_start_x+receiver_num_x*receiver_interval_x;
						ry_max=receiver_start_y+receiver_num_y*receiver_interval_y;
						rz_max=receiver_start_z+receiver_num_z*receiver_interval_z;

						choose_re=(receiver_start_z+bu)/nnz_device;

						warn("The next source set zero has been done!");
						warn("sx=%d,sy=%d,sz=%d",sx_real,sy_real,sz_real);
						warn("receiver_start_x=%d,rx_max=%d,receiver_start_x=%d",receiver_start_x,rx_max,receiver_start_x);
						warn("receiver_start_y=%d,ry_max=%d,receiver_start_y=%d",receiver_start_y,ry_max,receiver_start_y);
						warn("receiver_start_z=%d,rz_max=%d,receiver_start_z=%d",receiver_start_x,rz_max,receiver_start_z);
						warn("choose_ns=%d,remaining=%d",choose_ns,(sz_real+bu)%nnz_device+radius);
						warn("choose_re=%d,remaining=%d",choose_re,(receiver_start_z+bu)%nnz_device+radius);

						if(join_shot==0)
						{
//////////////////////////////////////////////////////////forward_together_using_smoothed_model//////////////////////////////////////////				
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////		
							forward_together_using_real_model(mgdevice);
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////	
//////////////////////////////////////////////////////////forward_together_using_real_model//////////////////////////////////////////////	
						
							if(isz==0&&isy==0&&isx==0)
							{
								if(vsp==0)	output_or_input_multicomponent_seismic(0);//////////////out put single shotgather
								else		output_or_input_multicomponent_seismic_vsp(0);//////////////out put single shotgather
								checkCudaErrors(cudaDeviceSynchronize());
							}
						}
///////////////////////////////////////////////////////////////////* record ending time */
						cudaEventRecord(stop);
				  		cudaEventSynchronize(stop);
				  		cudaEventElapsedTime(&mstimer, start, stop);
						totaltime_Modeling+=mstimer*1e-3;

/////////////////////////////////////////////the current shot  cost times
						logfile=fopen("log.txt","ab");//remember to free log file

						warn("one_shot_elastic_modeling has been done");

						warn("sz_real=%d,sy_real=%d,sx_real=%d current shot finished: %f (s)",sz_real,sy_real,sx_real,mstimer*1e-3);
						fprintf(logfile,"sz_real=%d,sy_real=%d,sx_real=%d current shot finished: %f (s)\n",sz_real,sy_real,sx_real,mstimer*1e-3);

/////////////////////////////////////////////to current shot has cost times

						warn("Modeling is done at current shot, total time cost: %f (s)",totaltime_Modeling);
						fprintf(logfile,"Modeling is done at current shot, total time cost: %f (s)\n\n",totaltime_Modeling);

						fclose(logfile);////important
					
		
						warn("forward end\n");


//////////////////////////////////////////////////**********************************************************************************//////////////////////////////////////////////////////////
//////////////////////////////////////////////////**********************************************************************************//////////////////////////////////////////////////////////
//////////////////////////////////////////////////**********************************************************************************//////////////////////////////////////////////////////////
//////////////////////////////////////////////////**********************************************************************************//////////////////////////////////////////////////////////
//////////////////////////////////////////////////**********************************************************************************//////////////////////////////////////////////////////////
//////////////////////////////////////////////////**********************************************************************************//////////////////////////////////////////////////////////
		if(RTM!=0)				warn("\nElastic RTM is beginning\nElastic RTM is beginning\nElastic RTM is beginning\n");
		else					warn("over");
//////////////////////////////////////////////////**********************************************************************************//////////////////////////////////////////////////////////
//////////////////////////////////////////////////**********************************************************************************//////////////////////////////////////////////////////////
//////////////////////////////////////////////////**********************************************************************************//////////////////////////////////////////////////////////
//////////////////////////////////////////////////**********************************************************************************//////////////////////////////////////////////////////////
//////////////////////////////////////////////////**********************************************************************************//////////////////////////////////////////////////////////
//////////////////////////////////////////////////**********************************************************************************//////////////////////////////////////////////////////////


						cudaEventRecord(start);/* record starting time */

						for(int i=0;i<GPU_N;i++)
						{
							checkCudaErrors(cudaSetDevice(gpuid[i]));
							set_zero_typedef_struct_wavefield(mgdevice,i);
							set_zero_typedef_struct_excitation(mgdevice,i);
							set_zero_typedef_struct_poyn(mgdevice,i);
							amp_max_idx=0,tp_max_idx=0;amp_max=0.0,tp_max=0.0;
						}
						checkCudaErrors(cudaDeviceSynchronize());////所有卡做到完，在进行下一步？
						
						sx_real=shot_start_x+isx*shot_interval_x;
						sy_real=shot_start_y+isy*shot_interval_y;
						sz_real=shot_start_z+isz*shot_interval_z;

						choose_ns=(sz_real+bu)/nnz_device;

						rx_max=receiver_start_x+receiver_num_x*receiver_interval_x;
						ry_max=receiver_start_y+receiver_num_y*receiver_interval_y;
						rz_max=receiver_start_z+receiver_num_z*receiver_interval_z;

						choose_re=(receiver_start_z+bu)/nnz_device;

						warn("The next source set zero has been done!");
						warn("sx=%d,sy=%d,sz=%d",sx_real,sy_real,sz_real);
						warn("receiver_start_x=%d,rx_max=%d,receiver_start_x=%d",receiver_start_x,rx_max,receiver_start_x);
						warn("receiver_start_y=%d,ry_max=%d,receiver_start_y=%d",receiver_start_y,ry_max,receiver_start_y);
						warn("receiver_start_z=%d,rz_max=%d,receiver_start_z=%d",receiver_start_x,rz_max,receiver_start_z);
						warn("choose_ns=%d,remaining=%d",choose_ns,(sz_real+bu)%nnz_device+radius);
						warn("choose_re=%d,remaining=%d",choose_re,(receiver_start_z+bu)%nnz_device+radius);

	
//////////////////////////////////////////////////////////forward_together_using_smoothed_model//////////////////////////////////////////				
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
							forward_together_using_smoothed_model(mgdevice);
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////	
//////////////////////////////////////////////////////////forward_together_using_smoothed_model//////////////////////////////////////////	

						if(isz==0&&isy==0&&isx==0)
						{
							output_3d_wavefiled_excitation_amp_time(mgdevice,isx,isy,isz);
							checkCudaErrors(cudaDeviceSynchronize());
							warn("output_3d_wavefiled_excitation_amp_time is end\n");

							//output_3d_poyn_p(mgdevice,isx,isy,isz);
							checkCudaErrors(cudaDeviceSynchronize());
							warn("output_3d_wavefiled_excitation_amp_time is end\n");
						}

						checkCudaErrors(cudaSetDevice(gpuid[choose_ns]));
						cubStatus = cublasIsamax(cubhandle, nnx*nny*nnz_device_append,mgdevice[choose_ns].ex_amp_d,1,&amp_max_idx);
						cubStatus = cublasIsamax(cubhandle, nnx*nny*nnz_device_append,mgdevice[choose_ns].ex_tp_d,1,&tp_max_idx);
						cudaMemcpy(&amp_max, &mgdevice[choose_ns].ex_amp_d[amp_max_idx], sizeof(float), cudaMemcpyDeviceToHost);
						cudaMemcpy(&tp_max, &mgdevice[choose_ns].ex_tp_d[tp_max_idx], sizeof(float), cudaMemcpyDeviceToHost);

						//cuda_cal_max<<<1,Block_Size,0,mgdevice[choose_ns].stream>>>(&amp_max,mgdevice[choose_ns].ex_amp_d,nnx*nny*nnz_device_append);
						//cuda_cal_max<<<1,Block_Size,0,mgdevice[choose_ns].stream>>>(&tp_max,mgdevice[choose_ns].ex_tp_d,nnx*nny*nnz_device_append);
						
						checkCudaErrors(cudaDeviceSynchronize());
						warn("amp_max=%f\n",amp_max);
						warn("tp_max=%f\n",tp_max);

						warn("forward modeling for Elastic RTM is end\n");
///////////////////////////////////////////////////////////////////////**********************************************///////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////**********************************************//////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////**********************************************///////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////**********************************************//////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////**********************************************///////////////////////////////////////////////////////
						warn("backward modeling for Elastic RTM is beg\n");

						for(int i=0;i<GPU_N;i++)
						{
							checkCudaErrors(cudaSetDevice(gpuid[i]));
							set_zero_typedef_struct_wavefield(mgdevice,i);
						}

							checkCudaErrors(cudaDeviceSynchronize());
							//warn("set_zero_typedef_struct_wavefield is passing");
						
						if(join_shot!=0)
						{
							if(vsp==0)	output_or_input_multicomponent_seismic(1);//////////////input three component surface
							if(vsp==1)	output_or_input_multicomponent_seismic_vsp(1);//////////input one Z component vsp
							if(vsp==3)	output_or_input_multicomponent_seismic_vsp(3);//////////input three component vsp
							checkCudaErrors(cudaDeviceSynchronize());
							//warn("output_or_input_multicomponent_seismic is passing");
						}


//////////////////////////////////////////////////////////backward_together_using_smoothed_model//////////////////////////////////////////				
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
							backward_together_using_smoothed_model(mgdevice);		
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////					
///////////////////////////////////////////////////////////backward_together_using_smoothed_model///////////////////////////////////////			
						
						warn("one shot Elastic RTM is end\n");

						output_3d_result(mgdevice,isx,isy,isz);

//////////////////////////////////////////////////////////////////////////////////////////////compensate_imaging_value_using_dependent_angle_information
						for(int i=0;i<GPU_N;i++)
							{
								checkCudaErrors(cudaSetDevice(gpuid[i]));

								//cuda_cal_angle_3D<<<dimGridwf_append,dimBlock,0,mgdevice[i].stream>>>(mgdevice[i].angle_pp_d,mgdevice[i].angle_ps_d,mgdevice[i].poyn_px_d,mgdevice[i].poyn_py_d,mgdevice[i].poyn_pz_d,mgdevice[i].poyn_rpx_d,mgdevice[i].poyn_rpy_d,mgdevice[i].poyn_rpz_d,mgdevice[i].poyn_rsx_d,mgdevice[i].poyn_rsy_d,mgdevice[i].poyn_rsz_d,nnx,nny,nnz_device_append);
								//imaging_compensate_dependent_angle<<<dimGridwf_append,dimBlock,0,mgdevice[i].stream>>>(mgdevice[i].vresult_pp_d,mgdevice[i].vresult_ps_d,mgdevice[i].angle_pp_d,mgdevice[i].angle_ps_d,nnx,nny,nnz_device_append);
							}	
					
								checkCudaErrors(cudaDeviceSynchronize());
								//if(fmod(it+1.0,1000.0)==1)	warn("cuda_cal_angle_3D is passing");
						//output_3d_result_compensate(mgdevice,isx,isy,isz);
						
///////////////////////////////////////////////////////////////////* record ending time */
						cudaEventRecord(stop);/* record ending time */
				  		cudaEventSynchronize(stop);
				  		cudaEventElapsedTime(&mstimer, start, stop);
						totaltime_RTM+=mstimer*1e-3;
						
/////////////////////////////////////////////the current shot  cost times
						logfile=fopen("log.txt","ab");//remember to free log file

						warn("one_shot_elastic_RTM has been done");
						warn("\nsz_real=%d,sy_real=%d,sx_real=%d current shot finished: %f (s)",sz_real,sy_real,sx_real,mstimer*1e-3);
						fprintf(logfile,"sz_real=%d,sy_real=%d,sx_real=%d current shot finished: %f (s)\n",sz_real,sy_real,sx_real,mstimer*1e-3);

/////////////////////////////////////////////to current shot has cost times

						warn("\nRTM is done at current shot, total time cost: %f (s)",totaltime_RTM);
						fprintf(logfile,"RTM is done at current shot, total time cost: %f (s)\n\n",totaltime_RTM);
						
						fclose(logfile);////important
				
					}
				}
			}
		

		

}


