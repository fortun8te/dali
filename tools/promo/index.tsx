import React from 'react';
import {AbsoluteFill, Composition, Img, Sequence, interpolate, registerRoot, staticFile, useCurrentFrame} from 'remotion';
const scenes = [
 {heading:'Mac audio.\nMore speakers.',copy:'Play your Mac on multiple\nAirPlay speakers.',image:'main.png',label:'MULTI-SPEAKER AIRPLAY FOR MAC'},
 {heading:'Choose\nyour room.',copy:'Select your speakers.\nSet their levels in DALI.',image:'speakers.png',label:'ONE APP. YOUR SPEAKERS.'},
 {heading:'Video, with\nthe sound.',copy:'An optional Chrome companion\nfor supported web video.',image:'browser.png',label:'DALI VIDEO SYNC'},
 {heading:'Open source.\nEarly preview.',copy:'Help test real speaker setups.',image:'main.png',label:'DALI FOR macOS'},
];
const Scene:React.FC<{index:number}> = ({index}) => {
 const frame=useCurrentFrame();
 const opacity=interpolate(frame,[0,10,140,150],[0,1,1,0],{extrapolateLeft:'clamp',extrapolateRight:'clamp'});
 const rise=interpolate(frame,[0,22],[16,0],{extrapolateRight:'clamp'});
 const scene=scenes[index];
 return <AbsoluteFill style={{opacity,flexDirection:'row',alignItems:'center',padding:'55px 90px',gap:60}}>
  <div style={{width:590,transform:`translateY(${rise}px)`}}>
   <div style={{fontFamily:'Arial',color:'#6995e7',fontSize:15,letterSpacing:2,marginBottom:30}}>{scene.label}</div>
   <div style={{fontFamily:'Georgia',fontSize:74,lineHeight:1.08,letterSpacing:-2,color:'#f0efec',whiteSpace:'pre-line'}}>{scene.heading}</div>
   <div style={{fontFamily:'Arial',fontSize:25,lineHeight:1.5,color:'#aaaeb5',marginTop:28,whiteSpace:'pre-line'}}>{scene.copy}</div>
   {index===3 && <div style={{fontFamily:'Arial',fontSize:23,color:'#f0efec',marginTop:36}}>github.com/fortun8te/dali</div>}
  </div>
  <div style={{flex:1,display:'flex',justifyContent:'center',transform:`translateY(${rise*.6}px)`}}>
   <Img src={staticFile(scene.image)} style={{height:565,maxWidth:420,objectFit:'contain',borderRadius:22}} />
  </div>
 </AbsoluteFill>;
};
const Dali:React.FC=()=> <AbsoluteFill style={{backgroundColor:'#090a0c'}}>
 {scenes.map((_,i)=><Sequence key={i} from={i*150} durationInFrames={150}><Scene index={i}/></Sequence>)}
 <div style={{position:'absolute',bottom:24,left:90,fontFamily:'Arial',fontSize:13,color:'#727780'}}>UI walkthrough · Developer preview · macOS 15+ / Apple Silicon</div>
</AbsoluteFill>;
registerRoot(()=> <Composition id="DaliAirPlay" component={Dali} durationInFrames={600} fps={30} width={1280} height={720}/>);
